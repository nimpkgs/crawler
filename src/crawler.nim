import std/[
    algorithm, os, sequtils, strformat, strutils,
    sets, tables, times,
]
import jsony, hwylterm, hwylterm/hwylcli, resultz
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
    case n
    of "@valid":
      names.incl nimpkgs.getValidPackages().toHashSet()
    of "@unreachable":
      names.incl nimpkgs.getUnreachablePackages().toHashSet()
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

proc updatePackages(ctx: CrawlerContext, nimpkgs: var Nimpkgs, names: seq[string]): E =
  info bbfmt"checking for new commits/versions on [b]{names.len}[/] packages"

  for i, name in names:
    info nimpkgs[name], fmt"[{i+1}/{names.len}]"
    case nimpkgs[name].checkRemotes().mapPkgErr(name)
    of Ok(hasNewCommits):
      if hasNewCommits:
        nimpkgs[name].updateVersions().mapPkgErr(name).isOkOr:
          handleError ctx, error
    of Err(e):
      handleError ctx, e

    dump nimpkgs[name]

  ok()

proc update(ctx: CrawlerContext, nimpkgs: var NimPkgs) =
  let names = collectNames(ctx.check, nimpkgs).bail()
  updatePackages(ctx, nimpkgs, names).bail("failure to check for new commits")

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

# TODO: add a verbosity flag
hwylCli:
  name "crawler"
  settings LongHelp, InferEnv
  flags:
    index:
      i nimpkgsPath
      T string
      ? "path to nimpkgs.json"
      * ctx.paths.index
    packages:
      i packagesPath
      T string
      ? "path to packages dir"
      * ctx.paths.packages
    mode:
      ? "crawler mode"
      T CrawlerMode
      * Update
    force:
      ? "packages to force update"
      - f
      T seq[string]
    check:
      ? "packages to check remote refs"
      T seq[string]
    `continue`:
      ? "ignore errors"
      i ignoreError
      - c

  run:
    ctx.paths.index = nimpkgsPath
    ctx.paths.packages = packagesPath
    ctx.force = force
    ctx.check = if check.len == 0 and force.len != 0: force else: check
    ctx.ignoreError = ignoreError

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
        getOfficialHead().bail("failed to fetch official package info").hash

    if prevHash != officialHash:
      info "packages.json has changed since the last crawl"

    let officialPackages = getOfficialPackages(officialHash).bail("failed to get official packages.json")
    var nimpkgs = newNimPkgs(ctx, officialPackages).bail("failed to initiate nimpkgs index")

    if mode in {Update, Fetch, Bootstrap}:
      if ctx.force.len > 0:
        let names = collectNames(ctx.force, nimpkgs).bail("failed to handle args for force: " & force.join(", "))
        ctx.check = if check.len == 0 and force.len != 0: names else: check
        purge(ctx, names).bail("pre-run cleanup failed")
        debug "reloading nimpkgs following purge"
        nimpkgs = newNimPkgs(ctx, officialPackages).bail("failed to initiate new nimpkgs")

      update ctx, nimpkgs

    if mode != Bootstrap and prevHash == officialHash:
      info "packages hash is the same, skipping recent check"
    else:
      added = getRecentlyAdded(officialHash, officialPackages).bail("failed to get recent packages")

    Index.init(nimpkgs, officialHash, added).dump()
    (cleanup nimpkgs).bail("post-run cleanup failed")



