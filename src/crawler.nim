import std/[
    algorithm, httpclient, strformat, strutils,
    options, osproc, os, sequtils,
    sets, tables, times
]

import jsony
import progress, packages

type
  CrawlerContext = object
    nimpkgsPath = "./nimpkgs.json"
    packagesPath = "./packages"
    dryrun, all: bool
    check: seq[string]
    filtered: seq[string]

proc fetchPackageJson(): string =
  var client = newHttpClient()
  try:
    return client.get(
        "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
      ).body()
  finally:
    client.close

proc cmpPkgs*(a, b: Package): int =
  cmp(toLowerAscii($a.name), toLowerAscii($b.name))

proc errQuit(args: varargs[string,`$`], code = 1) =
  writeLine(stderr, "ERROR: ",args.join(""))
  quit code

proc getPackages(): (Remote,seq[Package]) =
  let
    (remoteResponse, code) = execCmdEx(
      fmt"git ls-remote https://github.com/nim-lang/packages",
      env = gitEnv
    )
  if code != 0:
    errQuit("failed to get nim-lang/packages revision", code)
  let packagesRev = remoteResponse.parseRemotes().recent()
  var packages = fetchPackageJson().fromJson(seq[Package])
  packages.sort(cmpPkgs)
  return (packagesRev, packages)

proc updateNimPkg(
    pkg: Package,
    oldNimpkgs: NimPkgs,
    nimpkgs: var NimPkgs,
    selected: seq[string],
    pb: var ProgressBar,
    ctx: CrawlerContext,
) =
  var np: NimPackage

  if pkg.name in oldNimpkgs.packages:
    np = oldNimpkgs.packages[pkg.name]
  else:
    pb.echo "mapping new package: " & pkg.name
    np <- pkg

  pb.status np.name

  if np.deleted or np.isInvalid:
    np.deleted = true
  else:
    if np.outOfDate or ctx.all or np.name in selected:
      if checkRemotes(np, pb):
        pb.status "cloning -> " & np.name
        updateVersions np, pb

  dump np,ctx.packagesPath
  addPkg nimpkgs, np


proc filterPackageList(
    ctx: CrawlerContext, packages: seq[Package]
): seq[string] =
  let
    cliPkgs = ctx.check.toHashSet
    officialPkgs = packages.mapIt(it.name).toHashSet

  let unknown = (cliPkgs - officialPkgs).toSeq
  if unknown.len > 0:
    echo "unknownPackages: ", unknown.join(";")
    quit 1

  result = (cliPkgs * officialPkgs).toSeq

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

  var
    nimpkgs: NimPkgs
    pb = newProgressBar(packages.len)
  for i in 0..<packages.len:
    pb.show
    updateNimPkg(packages[i], oldNimpkgs, nimpkgs, selected, pb, ctx)
    inc pb

  nimpkgs.packagesHash = packagesRev.hash
  nimpkgs.updated = getTime()
  writeFile(ctx.nimpkgsPath, nimpkgs.toJson())

# NOTE: does this need to be it's own proc?
proc crawl(ctx: CrawlerContext) =
  if ctx.dryrun:
    echo "dryrun is a noop currently"
  if ctx.check.len > 0 and ctx.all:
    echo "-c/--check and -a/--all are mutually exclusive"
    quit 1

  updateNimPkgs ctx

when isMainModule:
  import std/parseopt
  const help = """
  crawler [flags]

  flags:
    --nimpkgs    path to nimpkgs.json (default: ./nimpkgs.json)
    --packages   directory to write package data (default: ./packages)
    -c,--check   list of packages to force query
    -n,--dryrun  only fetch remote commit info
    -a,--all     check remote's for all packages

  examples:
    crawler --check=,jsony,futhark
    crawler -na
  """

  var ctx = CrawlerContext()
  for kind, key, val in getopt(shortNoVal = {'a', 'n'}, longNoVal = @["all", "dryrun"]):
    case kind
    of cmdArgument:
      echo "unexpected arg: ", key
    of cmdLongOption, cmdShortOption:
      case key
      of "help","h":
        echo help; quit 0
      of "c","check":
        if val.startsWith(","):
          ctx.check &= val[1..^1].split(",")
        else:
          ctx.check.add val
      of "nimpkgs":
        ctx.nimpkgsPath = val
      of "packages":
        ctx.packagesPath = val
      of "a","all":
        ctx.all = true
      of "n","dryrun":
        ctx.dryrun = true
    of cmdEnd: discard

  crawl ctx

