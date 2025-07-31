import std/[
    os, sequtils, strformat, strutils,
    sets, tables, terminal, times,
]
import jsony, hwylterm, hwylterm/hwylcli
import ./[packages, lib]

type
  Paths = tuple
    nimpkgs = "./nimpkgs.json"
    packages = "./packages"

  CrawlerContext = object
    # nimpkgs: NimPkgs
    paths: Paths
    force: seq[string]

proc dump(ctx: CrawlerContext, nimpkgs: var NimPkgs) =
  nimpkgs.updated = getTime()
  for _, package in nimpkgs.packages.pairs:
    dump package, ctx.paths.packages
  writeFile(ctx.paths.nimpkgs, nimpkgs.toJson())

proc checkRequestedNames(nimpkgs: NimPkgs, names: seq[string]) =
  let knownPackages = nimpkgs.packages.keys().toSeq().toHashSet()
  let unknownPackages = names.toHashSet() - knownPackages
  if unknownPackages.len > 0:
    errQuit "unknown packages: ", unknownPackages.toSeq().join(";")

proc checkForCommits(ctx: CrawlerContext, nimpkgs: var Nimpkgs): seq[string] =
  let names =
    if ctx.force == @["@all"]:
      nimpkgs.getValidPackages()
    elif ctx.force.len > 0:
      checkRequestedNames nimpkgs, ctx.force
      ctx.force
    else:
      nimpkgs.getOutOfDatePackages()

  echo bbfmt"checking for new commits on [b]{names.len}[/] packages"

  with(Dots2, "checking commits"):
    for i, name in names:
      spinner.setText(fmt"[{i}/{names.len}] " &  name.bb("yellow"))
      if nimpkgs[name].checkRemotes():
        result.add name

proc checkForTags(ctx: CrawlerContext, nimpkgs: var NimPkgs, names: seq[string]) =
  echo bbfmt"checking for new tags in [b]{names.len}[/] packages"

  with(Dots2, bb"fetching package info"):

    for i, name in names:
      spinner.setText bbfmt"[[{i}/{names.len}] [yellow]{name}[/]"
      updateVersions nimpkgs[name]
      # dump nimpkgs[name], ctx.paths.packages

proc update(ctx: CrawlerContext, nimpkgs: var NimPkgs) =
  let names = checkForCommits(ctx, nimpkgs)

  if names.len > 0:
    checkForTags ctx, nimpkgs, names
  else:
    echo "no packages need to be checked for new tags"

  setRecent nimpkgs

proc checkPaths(ctx: CrawlerContext, bootstrap: bool) =
  if bootstrap: return

  var bail = false

  bail |= not ctx.paths.nimpkgs.fileExists
  bail |= not ctx.paths.packages.dirExists

  if bail:
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

  run:
    var ctx = CrawlerContext(
      paths: (nimpkgsPath, packagesPath),
      force: force,
    )

    checkPaths ctx, bootstrap
    createDir ctx.paths.packages
    createDir "repos"

    var nimpkgs = newNimPkgs(ctx.paths.nimpkgs)
    update ctx, nimpkgs
    dump ctx, nimpkgs

