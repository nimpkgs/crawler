import std/[algorithm, os, sequtils, sets, strformat, strutils, tables, times]
import chronos, hwylterm, jsony
import chronos/asyncsync
import hwylterm/hwylcli
import ./[packages, lib]

type
  RecentPackages = object
    added: seq[string]
    released: OrderedTable[string, string]
  Index* = object
    updated*: Time
    recent: RecentPackages
    packagesHash*: string
    packages*: seq[NimPackage]

proc init(T: typedesc[Index], nimpkgs: NimPkgs, packagesHash: string , added: seq[string]): T =
  var packages = nimpkgs.values().toSeq()
  let released = getRecentlyReleased(nimpkgs)

  # before dumping the full index we drop some of the metadata
  for package in packages.mitems:
    package.setMetadataForIndex()

  result.updated = getTime()
  result.recent = RecentPackages(added: added, released: released)
  result.packagesHash = packagesHash
  result.packages = packages

proc dump(index: Index) =
  writeFile(ctx.paths.index, index.toJson())

proc cleanup(nimpkgs: NimPkgs): E =
  for (kind, path) in walkDir(ctx.paths.packages):
    if kind notin {pcDir, pcLinkToDir}:
      return err fmt"unexpected file in packages directory: {path}"
    for (kind, path) in walkDir(path):
      let name = path.lastPathPart
      if name notin nimpkgs:
        info fmt"removing individual package data for: {name}"
        attempt(fmt"error removing directory: {path}"):
          removeDir path
  ok()

# BUG: if @unreachable is given to force the names no longer work, seperate the collect names from purge
proc collectNames(spec: seq[string], nimpkgs: NimPkgs): R[seq[string]] =
  var names, unknown: HashSet[string]
  if spec.len == 0:
    return ok nimpkgs.getOutOfDatePackages().sorted(cmpPkgs)
  for n in spec:
    const selectors = ["@valid", "@unreachable", "@unknown"] # TODO: use enum instead?
    if n.startsWith("@"):
      case n[1..^1]:
      of "valid":
        names.incl nimpkgs.getValidPackages().toHashSet()
      of "unreachable":
        names.incl nimpkgs.getUnreachablePackages().toHashSet()
      of "unknown":
        names.incl nimpkgs.getUnknownPackages().toHashSet()
      else:
        return err "unknown special selector: $# must be one of: $#" % [n, selectors.join(", ")]
    else:
      if n notin nimpkgs:
        unknown.incl n
      else:
        names.incl n
  if unknown.len > 0:
    return err "unknown package(s): " & unknown.toSeq().join(";")

  ok(names.toSeq().sorted(cmpPkgs))

proc purge*(ctx: CrawlerContext, names: seq[string]): E =
  ## remove the packages/pkg.json for any existing package given to "force"
  if ctx.force.len == 0:
    return ok()
  for name in names:
    let path = pkgPath(name)
    if fileExists(path):
      attempt(fmt"error removing file: {path}"):
        removeFile(path)
    else:
      debug fmt"{path} does not exist...ignoring"
  ok()

proc checkPackage(
  sem: AsyncSemaphore,
  pkg: NimPackage,
  ctx: CrawlerContext,
  idx, total: int
): Future[CheckResult] {.async.} =
  await sem.acquire()
  defer: sem.release()
  info pkg, fmt"[{idx}/{total}] checking"
  let res = (await checkRemotes(pkg)).mapPkgErr(pkg.name)
  if res.isErr:
    error res.error()
    return CheckResult(hasNewCommits: false, pkg: pkg)
  let r = res.get()
  if r.err != "":
    error r.err
  return r

proc updatePackage(
  sem: AsyncSemaphore,
  pkg: NimPackage,
  ctx: CrawlerContext,
  idx, total: int
): Future[NimPackage] {.async.} =
  await sem.acquire()
  defer: sem.release()
  info pkg, fmt"[{idx}/{total}] updating"
  let res = (await updateVersions(pkg)).mapPkgErr(pkg.name)
  if res.isOk:
    return res.get()
  error res.error()
  return pkg

proc updatePackages(
  ctx: CrawlerContext,
  nimpkgs: NimPkgs,
  names: seq[string]
): Future[NimPkgs] {.async.} =

  # Phase 1: check all remotes concurrently
  info bbfmt"checking remotes for [b]{names.len}[/] packages"
  let checkSem = newAsyncSemaphore(ctx.jobs.remote)
  var checkFutures: seq[Future[CheckResult]]
  for i, name in names:
    checkFutures.add checkPackage(checkSem, nimpkgs[name], ctx, i + 1, names.len)
  await allFutures(checkFutures)

  # Collect results; find packages with new commits
  var pkgs = nimpkgs
  var toUpdate: seq[string]
  for i, name in names:
    let r = checkFutures[i].read()
    pkgs[name] = r.pkg
    if r.hasNewCommits:
      toUpdate.add name

  # Phase 2: clone/fetch/nimble dump only the packages that changed
  if toUpdate.len > 0:
    info bbfmt"updating [b]{toUpdate.len}[/] packages with new commits"
    let updateSem = newAsyncSemaphore(ctx.jobs.fetch)
    var updateFutures: seq[Future[NimPackage]]
    for i, name in toUpdate:
      updateFutures.add updatePackage(updateSem, pkgs[name], ctx, i + 1, toUpdate.len)
    await allFutures(updateFutures)
    for i, name in toUpdate:
      pkgs[name] = updateFutures[i].read()

  {.cast(gcsafe).}:
    # Dump all processed packages
    for name in names:
      dump pkgs[name]

  return pkgs

proc update(ctx: CrawlerContext, nimpkgs: var NimPkgs) =
  let names = collectNames(ctx.check, nimpkgs).bail()
  nimpkgs = waitFor updatePackages(ctx, nimpkgs, names)

proc checkPaths() =
  var toBail = false

  toBail |= not ctx.paths.index.fileExists
  toBail |= not ctx.paths.packages.dirExists

  if toBail:
    errQuit bb"expected existing [b]nimpkgs[/] registry, " &
      bb"run with [b]--mode Bootstrap[/] to create needed files/directories"

proc loadIndex(): R[Index] =
  if not fileExists(ctx.paths.index):
    return err "index does not exist " &
      $bb"run with [b]--mode Bootstrap[/] to create needed files/directories"
  attempt"failed to load previous index":
    return ok(readFile(ctx.paths.index).fromJson(Index))


type
  CrawlerMode = enum
    Update ## fetch + recent (recent is implied)
    Fetch  ## uses existing packages.json hash, but updates package versions
    Recent ## force update recent using the current hash
    Bootstrap ## initiate then update

const crawlerModeHelp = "crawler mode" & "\n\nchoices: " & enumNames(CrawlerMode).join(",")

hwylCli:
  name "crawler"
  settings LongHelp, InferEnv
  flags:
    paths:
      T Paths
      ? "paths for nimpkgs registry"
      * default(Paths)
    mode:
      ? crawlerModeHelp
      T CrawlerMode
      * Update
    force:
      ? "packages to force update"
      - f
      T seq[string]
    check:
      ? "packages to check remote refs"
      T seq[string]
    j|jobs:
      ? """
      max concurrent jobs

      total jobs used for each phase
        remote: first phase (git ls-remote)
        fetch: second phase (git clone, nimble dump)
      """
      T Jobs
      * default(Jobs)
  run:
    ctx.paths = paths
    ctx.force = force
    ctx.check = if check.len == 0 and force.len != 0: force else: check
    ctx.jobs = jobs

    if mode != Bootstrap:
      checkPaths()

    createDir ctx.paths.packages
    createDir "repos"

    var prevHash: string
    var added: seq[string]
    if mode != Bootstrap:
      let prev = loadIndex().bail("error loading previous index")
      prevHash = prev.packagesHash
      added = prev.recent.added
    else:
      info "Running in [yellow]BOOTSTRAP[/] mode".bb

    let officialHash =
      if mode in {Recent,Fetch}: prevHash
      else:
        debug "fetching new official packages commit info"
        (waitFor getOfficialHead()).bail("failed to fetch official package info").hash

    if prevHash != officialHash:
      info "packages.json has changed since the last crawl"

    let officialPackages = getOfficialPackages(officialHash).bail("failed to get official packages.json")
    var nimpkgs = newNimPkgs(ctx, officialPackages).bail("failed to initiate nimpkgs index")

    if mode in {Update, Fetch, Bootstrap}:
      if mode == Bootstrap:
        ctx.force.add officialPackages.mapIt(it.name)
      if ctx.force.len > 0:
        let names = collectNames(ctx.force, nimpkgs).bail("failed to handle args for force: " & force.join(", "))
        ctx.check.add names
        purge(ctx, names).bail("pre-run cleanup failed")
        debug "reloading nimpkgs following purge"
        nimpkgs = newNimPkgs(ctx, officialPackages).bail("failed to initiate new nimpkgs")

      update ctx, nimpkgs

    if mode != Bootstrap and prevHash == officialHash:
      info "packages hash is the same, skipping recent check"
    else:
      added = (waitFor getRecentlyAdded(officialHash, officialPackages)).bail("failed to get recent packages")

    Index.init(nimpkgs, officialHash, added).dump()
    (cleanup nimpkgs).bail("post-run cleanup failed")



