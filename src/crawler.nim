import std/[
    algorithm, httpclient, strformat, strutils,
    options, osproc, os, sequtils,
    sets, tables, terminal, times
]
import jsony, hwylterm, hwylterm/hwylcli
import ./[packages]

type
  CrawlerContext = object
    nimpkgsPath = "./nimpkgs.json"
    packagesPath = "./packages"
    dryrun, all, skipRecent: bool
    names: seq[string]

const nimlangPackageUrl =
  "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"

proc fetchPackageJson(): string =
  var client = newHttpClient()
  try:
    result = client.get(nimLangPackageUrl).body()
  finally:
    close client

proc cmpPkgs*(a, b: Package): int =
  cmp(toLowerAscii($a.name), toLowerAscii($b.name))

proc errQuitWithCode(code: int, args: varargs[string, `$`]) =
  writeLine stderr, $bb"[b red]ERROR[/]: ", args.join("")
  quit code

proc errQuit(args: varargs[string, `$`]) =
  errQuitWithCode 1, args

proc getPackages(): (Remote,seq[Package]) =
  let
    (remoteResponse, code) = execCmdEx(fmt"git ls-remote https://github.com/nim-lang/packages", env = gitEnv)
  if code != 0:
    errQuitWithCode code, "failed to get nim-lang/packages revision"
  let packagesRev = remoteResponse.parseRemotes().recent()
  var packages = fetchPackageJson().fromJson(seq[Package])
  packages.sort(cmpPkgs)
  return (packagesRev, packages)

# TODO: do I need to be "dumping here"
proc fromExisting(ctx: CrawlerContext, nimpkgs: NimPkgs, package: Package): NimPackage =
  if package.name in nimpkgs.packages:
    result = nimpkgs.packages[package.name]

    # if a new package has been generated then we need to fetch version info anew
    if result.url != package.url:
      result <- package
      result.outOfDate = true
      dump result, ctx.packagesPath
  else:
    result <- package
    dump result, ctx.packagesPath

  if result.isInvalid:
    result.deleted = true

proc update(ctx: CrawlerContext, p: var NimPackage): bool =
  if p.deleted: return
  if p.outOfDate or ctx.all:
    if checkRemotes(p):
      updateVersions p
      return true

func diff(filtered: seq[Package], requested: openArray[string]): seq[string] =
  let names = filtered.mapIt(it.name).toHashSet
  (names - requested.toHashSet).toSeq()

proc filter(packages: seq[Package], ctx: CrawlerContext): seq[Package] =
  if ctx.names.len == 0 or ctx.all:
    return packages

  for p in packages:
    if p.name in ctx.names:
      result.add p

  if result.len == 0:
    errQuit "no packages matched selected names: ", ctx.names.join(";")

  if result.len != ctx.names.len:
    errQuit "unknownPackages: ", diff(result, ctx.names).join(";")

proc gitCmd(cmd: string): string =
  let (output, code) = execCmdEx cmd
  result = output
  if code != 0:
    echo "failed to run cmd: " & cmd
    echo "output\n:" & output
    quit 1

func packageFilesFromGitOutput(output: string): seq[string] =
  output.splitLines().filterIt(it.startsWith("packages/"))

proc recent(existing: seq[string]): seq[string] =
  ## brute force attempt to establish the most recent packages added to packages.json

  let lsFilesOutput = gitCmd("git ls-files --others --exclude-standard")
  let logOutput = gitCmd("git log --pretty'' --name-only")
  var paths = packageFilesFromGitOutput(lsFilesOutput & logOutput)
  paths.reverse()
  result = paths
    .toOrderedSet()
    .toSeq()[^10..^1]
    .mapIt(it.replace("packages/","")
    .replace(".json",""))
    .filterIt(it in existing)
  result.reverse()

proc setRecent(nimpkgs: var  NimPkgs) =
  nimpkgs.recent = recent(nimpkgs.packages.keys.toSeq())

proc updateNimPackage(
  ctx: CrawlerContext,
  nimpkgs: var NimPkgs,
  nimPackage: var NimPackage,
) =
  if update(ctx, nimPackage):
    dump nimPackage, ctx.packagesPath
  add nimpkgs, nimPackage

proc dump(ctx: CrawlerContext, nimpkgs: NimPkgs) =
  writeFile(ctx.nimpkgsPath, nimpkgs.toJson())

proc newNimPkgs(ctx: CrawlerContext): NimPkgs =
  if fileExists ctx.nimpkgsPath:
    result = readFile(ctx.nimpkgsPath).fromJson(typeof(result))

proc updateNimPkgs(ctx: CrawlerContext) =
  createDir ctx.packagesPath
  createDir "repos"

  let (packagesRev, packages) = getPackages()
  let filteredPackages = packages.filter(ctx)
  let totalPackages = filteredPackages.len

  var nimpkgs = newNimPkgs(ctx)
  nimpkgs.packagesHash = packagesRev.hash

  with(Dots2, bb"fetching package info"):

    for i, package in filteredPackages:
      spinner.setText fmt"package [[{i}/{totalPackages}]: {package.name}"

      var nimPackage = fromExisting(ctx, nimpkgs, package)
      updateNimPackage ctx, nimpkgs, nimPackage

  nimpkgs.updated = getTime()

  setRecent nimpkgs
  dump ctx, nimpkgs

proc checkPaths(ctx: CrawlerContext) =
  if getEnv("BOOTSTRAP_NIMPKGS") != "":
    return

  var bail = false

  bail |= not ctx.nimpkgsPath.fileExists
  bail |= not ctx.packagesPath.dirExists

  if bail:
    errQuit bb"expected existing [b]nimpkgs[/] registry, run with [b]BOOTSTRAP_NIMPKGS[/] to created needed files/directories"

let ctxDefault = CrawlerContext()

hwylCli:
  name "crawler"
  flags:
    nimpkgs:
      i nimpkgsPath
      T string
      ? "path to nimpkgs.json (default: ./nimpkgs.json)"
      * ctxDefault.nimpkgsPath
    packages:
      i packagesPath
      T string
      ? "path to packages dir (default: ./packages)"
      * ctxDefault.packagesPath
    names:
      T seq[string]
      ? "list of packages to check"
    # dryrun:
      # ? "only fetch remote commit info"
      # - n
    all:
      ? "check remote's for all packages"
      - a
  run:
    if names.len > 0 and all:
      echo "--names and -a/--all are mutually exclusive"
      quit 1

    var ctx = CrawlerContext(
      packagesPath: packagesPath,
      nimpkgsPath: nimpkgsPath,
      names: names,
      all: all,
    )

    checkPaths ctx
    updateNimPkgs ctx
