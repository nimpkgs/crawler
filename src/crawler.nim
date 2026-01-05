import std/[
    algorithm, os, sequtils, strformat, strutils,
    sets, tables, times,
]
import jsony, hwylterm, hwylterm/hwylcli, resultz
import ./[packages, lib]

# TODO: refactor so this object is created at dump time...

type
  NimPkgsSimple* = object
    updated*: Time
    recent*: seq[string]
    packagesHash*: string
    packages*: seq[NimPackage] # only this one needs to be a table?

proc simplify(nimpkgs: NimPkgs): NimpkgsSimple =
  result.updated = getTime()
  result.recent = nimpkgs.recent
  result.packages = nimpkgs.packages.values().toSeq()
  result.packagesHash = nimpkgs.packagesHash

proc dump(ctx: CrawlerContext, nimpkgs: var NimPkgs) =
  nimpkgs.updated = getTime()

  # before dumping the full index we drop some of the metadata
  for _, package in nimpkgs.packages.mpairs:
    package.setTimes()
    package.clearMetadataForIndex()

  let simple = nimpkgs.simplify()
  writeFile(ctx.paths.nimpkgs, simple.toJson())

proc cleanup(ctx: CrawlerContext, nimpkgs: NimPkgs) =
  for (_, path) in walkDir(ctx.paths.packages):
    let name = path.splitFile.name
    if name notin nimpkgs.packages:
      echo fmt"removing individual package data for: {name}"
      removeFile path

proc collectNames(ctx: CrawlerContext, nimpkgs: NimPkgs): R[seq[string]] =
  var names, unknown: HashSet[string]
  if ctx.check.len == 0:
    return ok nimpkgs.getOutOfDatePackages().sorted(cmpPkgs)
  for n in ctx.check:
    case n
    of "@valid":
      names.incl nimpkgs.getValidPackages().toHashSet()
    of "@unreachable":
      names.incl nimpkgs.getUnreachablePackages().toHashSet()
    else:
      if n notin nimpkgs.packages:
        unknown.incl n
      else:
        names.incl n
  if unknown.len > 0:
    return err "unknown package(s): " & unknown.toSeq().join(";")

  ok(names.toSeq().sorted(cmpPkgs))

proc checkForCommits(ctx: var CrawlerContext, nimpkgs: var Nimpkgs, names: seq[string]): R[seq[string]] =
  hecho bbfmt"checking for new commits on [b]{names.len}[/] packages"

  var toCheck: seq[string]
  var p = newProgress(ctx)
  for name in p.progress(names):
    case nimpkgs[name].checkRemotes().mapPkgErr(name)
    of Ok(hasNewCommits):
      if hasNewCommits:
        toCheck.add name
    of Err(e):
      handleError ctx, e
    dump nimpkgs[name], ctx.paths.packages

  ok toCheck

proc checkForTags(ctx: var CrawlerContext, nimpkgs: var NimPkgs, names: seq[string]): R[void] =
  hecho bbfmt"checking for new tags in [b]{names.len}[/] packages"

  var p = newProgress(ctx)
  for name in p.progress(names):
    nimpkgs[name]
      .updateVersions()
      .mapPkgErr(name)
      .isOkOr:
        handleError ctx, error

    dump nimpkgs[name], ctx.paths.packages

  ok()

proc update(ctx: var CrawlerContext, nimpkgs: var NimPkgs) =
  let names = collectNames(ctx, nimpkgs).bail()
  let outOfDatePkgs = checkForCommits(ctx, nimpkgs, names).bail("failure to check for new commits")

  if outOfDatePkgs.len > 0:
    checkForTags(ctx, nimpkgs, outOfDatePkgs).bail("failure to get updated tags")
  else:
    hecho "no packages need to be checked for new tags"

  setRecent(nimpkgs).bail("failure to set recent packages")

proc checkPaths(ctx: CrawlerContext, bootstrap: bool) =
  if bootstrap: return

  var toBail = false

  toBail |= not ctx.paths.nimpkgs.fileExists
  toBail |= not ctx.paths.packages.dirExists

  if toBail:
    errQuit bb"expected existing [b]nimpkgs[/] registry, " &
      bb"run with [b]--bootstrap[/] to create needed files/directories"


let ctxDefault = CrawlerContext()

hwylCli:
  name "crawler"
  settings LongHelp, InferEnv
  flags:
    nimpkgs:
      i nimpkgsPath
      T string
      ? "path to nimpkgs.json"
      * ctxDefault.paths.nimpkgs
    packages:
      i packagesPath
      T string
      ? "path to packages dir"
      * ctxDefault.paths.packages
    bootstrap:
      ? "generate a new nimpkgs registry"
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

    var ctx = CrawlerContext(
      paths: (nimpkgsPath, packagesPath),
      force: force,
      check: if check.len == 0 and force.len != 0: force else: check,
      ignoreError: ignoreError
    )

    checkPaths ctx, bootstrap
    createDir ctx.paths.packages
    createDir "repos"

    var nimpkgs = newNimPkgs(ctx).bail()
    update ctx, nimpkgs
    dump ctx, nimpkgs
    cleanup ctx, nimpkgs

