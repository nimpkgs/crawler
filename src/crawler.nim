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
    check: seq[string]
    filtered: seq[string]

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

proc errQuit(args: varargs[string,`$`], code = 1) =
  writeLine(stderr, "ERROR: ", args.join(""))
  quit code

proc getPackages(): (Remote,seq[Package]) =
  let
    (remoteResponse, code) = execCmdEx(fmt"git ls-remote https://github.com/nim-lang/packages", env = gitEnv)
  if code != 0:
    errQuit("failed to get nim-lang/packages revision", code)
  let packagesRev = remoteResponse.parseRemotes().recent()
  var packages = fetchPackageJson().fromJson(seq[Package])
  packages.sort(cmpPkgs)
  return (packagesRev, packages)


func fromExisting(nimpkgs: NimPkgs, package: Package): NimPackage =
  if package.name in nimpkgs.packages:
    result = nimpkgs.packages[package.name]
  else:
    result <- package

  if result.isInvalid:
    result.deleted = true

# TODO: refactor
proc newNimPackage(
    package: Package,
    nimpkgs: NimPkgs,
    selected: seq[string],
    packagesPath: string,
    all: bool,
): NimPackage =

  result = fromExisting(nimpkgs, package)

  # TODO: propagate selected up to a higher level
  # Selected/all should be incapsulated in a "force" param from a higher level
  if not result.deleted and (
    all or result.outOfDate or result.name in selected
    ):
      if checkRemotes(result):
        updateVersions result

  dump result, packagesPath

proc filterPackageList(
    ctx: CrawlerContext,
    packages: seq[Package]
): seq[string] =
  let
    cliPkgs = ctx.check.toHashSet
    officialPkgs = packages.mapIt(it.name).toHashSet

  let unknown = (cliPkgs - officialPkgs).toSeq
  if unknown.len > 0:
    echo "unknownPackages: ", unknown.join(";")
    quit 1

  result = (cliPkgs * officialPkgs).toSeq

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

proc updateNimPkgs(ctx: CrawlerContext) =
  createDir ctx.packagesPath
  createDir "repos"

  let
    oldNimpkgs =
      if fileExists ctx.nimpkgsPath:
        readFile(ctx.nimpkgsPath).fromJson(NimPkgs)
      else:
        NimPkgs()
    (packagesRev, packages) = getPackages()
    selected = filterPackageList(ctx, packages)
    totalPackages = packages.len

  var nimpkgs: NimPkgs

  with(Dots2, bb"fetching package info"):

    for i, package in packages:
      # BUG: spinner.setText sefaults if the spinner isn't actually active
      if isatty(spinner.file):
        spinner.setText fmt"package [[{i}/{totalPackages}]: {package.name}"
      addPkg nimpkgs, newNimPackage(package, oldNimpkgs, selected, ctx.packagesPath, ctx.all)

  nimpkgs.packagesHash = packagesRev.hash
  nimpkgs.updated = getTime()

  setRecent nimpkgs

  writeFile(ctx.nimpkgsPath, nimpkgs.toJson())

hwylCli:
  name "crawler"
  flags:
    nimpkgs:
      i nimpkgsPath
      T string
      ? "path to nimpkgs.json (default: ./nimpkgs.json)"
      * "./nimpkgs.json"
    packages:
      i packagesPath
      T string
      ? "path to packages dir (default: ./packages)"
      * "./packages"
    check:
      T seq[string]
      ? "list of packages to force query"
      - c
    # dryrun:
      # ? "only fetch remote commit info"
      # - n
    all:
      ? "check remote's for all packages"
      - a
  run:
    if check.len > 0 and all:
      echo "-c/--check and -a/--all are mutually exclusive"
      quit 1

    var ctx = CrawlerContext(
      packagesPath: packagesPath,
      nimpkgsPath: nimpkgsPath,
      check: check,
      all: all,
      dryrun: false,
    )

    if ctx.dryrun:
      echo "dryrun is a noop currently"

    updateNimPkgs ctx
