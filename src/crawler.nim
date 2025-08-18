import std/[
    algorithm, os, sequtils, strformat, strutils,
    sets, tables, times,
]
import jsony, hwylterm, hwylterm/hwylcli, results
import ./[packages, lib]


proc dump(ctx: CrawlerContext, nimpkgs: var NimPkgs) =
  nimpkgs.updated = getTime()
  for _, package in nimpkgs.packages.pairs:
    dump package, ctx.paths.packages
  writeFile(ctx.paths.nimpkgs, nimpkgs.toJson())

proc collectNames(ctx: CrawlerContext, nimpkgs: NimPkgs): seq[string] =
  var names, unknown: HashSet[string]
  if ctx.check.len == 0:
    return nimpkgs.getOutOfDatePackages().sorted(cmpPkgs)
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
    errQuit "unknown package(s): ", unknown.toSeq().join(";")

  names.toSeq().sorted(cmpPkgs)

proc checkForCommits(ctx: var CrawlerContext, nimpkgs: var Nimpkgs): seq[string] =
  let names = collectNames(ctx, nimpkgs)
  echo bbfmt"checking for new commits on [b]{names.len}[/] packages"
  # var spinner = newSpinny("")
  var p = newProgress(ctx)
  for name in p.progress(names):
    let toUpdate =
      nimpkgs[name]
      .checkRemotes()
      .mapPkgErr(name)
      .valueOr:
        handleError ctx, error
    if toUpdate:
      result.add name

proc checkForTags(ctx: var CrawlerContext, nimpkgs: var NimPkgs, names: seq[string]) =
  echo bbfmt"checking for new tags in [b]{names.len}[/] packages"

  var p = newProgress(ctx)
  for name in p.progress(names):
    nimpkgs[name]
      .updateVersions()
      .mapPkgErr(name)
      .isOkOr:
        handleError(ctx, error)

proc update(ctx: var CrawlerContext, nimpkgs: var NimPkgs) =
  let names = checkForCommits(ctx, nimpkgs)

  if names.len > 0:
    checkForTags ctx, nimpkgs, names
  else:
    echo "no packages need to be checked for new tags"

  setRecent(nimpkgs).bail("failed to set recent packages")

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

