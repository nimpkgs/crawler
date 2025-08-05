import std/[
    algorithm, httpclient, options, os, osproc, sequtils,
    sets, strformat, strtabs, strutils, tables, times,
]
from std/json import pretty

import jsony

import ./lib


proc defaultEnv(): StringTableRef =
  result = newStringTable(mode = modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  # no prompting from git
  result["GIT_TERMINAL_PROMPT"] = "0"
  result.del "SSH_KEYPASS"

let gitEnv* = defaultEnv()

type
  NimPkgCrawlerError* = object of CatchableError

  Remote* = object
    hash*, `ref`*: string

  Version = object
    tag*, hash*: string
    time*: Time

  Package* = object
    name*, url*, `method`*, description*: string
    license*, web*, doc*, alias*: string
    tags*: seq[string]

  NimPackageStatus* = enum # order matters here since ranges are used
    Unknown,
    OutOfDate,
    UpToDate,
    Alias,
    Unreachable,
    Deleted

  NimPackage* = object
    name*, url*, `method`*, description*,
      license*, web*, doc*, alias*: string
    lastCommitHash*: string
    lastCommitTime*: Time
    versions*: seq[Version]
    tags*: seq[string]
    status*: NimPackageStatus

  NimPkgs* = object
    updated*: Time
    recent*: seq[string]
    packagesHash*: string
    packages*: OrderedTable[string, NimPackage]

func contains(nimpkgs: var NimPkgs, p: Package): bool =
  p.name in nimpkgs.packages

func add*(nimpkgs: var NimPkgs, p: NimPackage) =
  nimpkgs.packages[p.name] = p

func noCommitData(np: NimPackage): bool =
  np.lastCommitTime == fromUnix(0)

proc recentlyUpdated(np: NimPackage, duration = initDuration(days = 7)): bool =
  (getTime() - np.lastCommitTime) < duration

# continue to maintain status in nimpkgs.json / packages/{package}.json
proc postHook*(np: var NimPackage) =
  if np.status in Alias..Deleted:
    return

  if np.recentlyUpdated or np.noCommitData:
    np.status = OutOfDate

proc skipHook*(T: typedesc[NimPackage], key: static string): bool =
  key in ["outOfDate"]

template dumpKey(s: var string, v: string) =
  const v2 = v.toJson() & ":"
  s.add v2

proc isNull(v: string): bool = v == ""
proc isNull(v: seq[Version]): bool = v == @[]
proc isNull[T](v: seq[T]): bool = v == newSeq[T]()
proc isNull(v: Time): bool = v == Time()
proc isNull(v: bool): bool = not v
proc isNull[A, B](v: OrderedTable[A, B]): bool =
  v.len() == 0
proc isNull(v: NimPackageStatus): bool = 
  v == Unknown # error check this instead?
proc dumpHook(s: var string, v: Time) = s.add $v.toUnix()

proc parseHook*(s: string, i: var int, v: var Time) =
  var num: int
  parseHook(s, i, num)
  v = fromUnix(num)

proc dumpHook*(s: var string, v: NimPackage | NimPkgs) =
  ## special dumpHook to skip keys and any empty values
  s.add '{'
  var i = 0
  for k, e in v.fieldPairs:
    when compiles(skipHook(typeof(v), k)):
      when skipHook(typeof(v), k):
        discard
      else:
        if not e.isNull():
          if i > 0:
            s.add ','
          s.dumpKey(k)
          s.dumpHook(e)
          inc i
    else:
      if not e.isNull():
        if i > 0:
          s.add ','
        s.dumpKey(k)
        s.dumpHook(e)
        inc i
  s.add '}'


proc map*(np: var NimPackage, p: Package) =
  ## map Package onto np
  np.name = p.name
  np.url = p.url
  np.`method` = p.`method`
  np.description = p.description
  np.license = p.license
  np.web = p.web
  np.doc = p.doc
  np.alias = p.alias
  np.tags = p.tags
  if "deleted" in p.tags:
    np.status = Deleted
  if np.alias != "":
    np.status = Alias

proc `<-`*(np: var NimPackage, p: Package) {.inline.} = map np, p

proc repo(pkg: NimPackage): tuple[url: string, path: string] =
  result.url =
    if "?subdir=" in pkg.url: pkg.url.split("?subdir=")[0]
    else: pkg.url
  let s = result.url.split("/")
  result.path = "repos" / s[^2..^1].join("-") & ".git"

proc gitLastestCommit*(pkg: var NimPackage) =
  let (output, code) =
    execCmdEx(
      fmt"git --git-dir={pkg.repo.path} show --format='%H|%ct' -s",
      options = {poUsePath},
    )
  if code != 0:
    echo output
    echo fmt"error fetching last commit for {pkg.name}"
    return
  let s = output.strip().split("|")
  pkg.lastCommitHash = s[0]
  pkg.lastCommitTime = fromUnix(parseInt(s[1]))

proc gitLog*(pkg: NimPackage): string =
  let cmd =
    fmt"git --git-dir={pkg.repo.path} log --format='%H|%D|%ct'" &
    " --decorate-refs='refs/tags/v*.*' --tags --no-walk"
  let (output, code) = execCmdEx(cmd, options = {poUsePath})
  if code != 0:
    echo cmd
    echo output
    echo fmt"error fetching history for package: {pkg}"
  return output

proc gitClone*(pkg: NimPackage) =
  let (url, path) = pkg.repo()
  if not dirExists path:
    let (_, errCode) = execCmdEx fmt"git clone --filter=tree:0 --bare {url} {path}"
    if errCode != 0:
      echo fmt"error cloning {pkg.name}"

proc gitUpdateVersions(pkg: var NimPackage) =
  # TODO: update to only go as deep as necessary with clone
  pkg.gitClone
  pkg.versions = @[]
  pkg.gitLastestCommit
  if pkg.lastCommitTime == fromUnix(0):
    quit fmt"pkg: {pkg.name} failed to update last commit time?"
  let output = pkg.gitLog
  if output != "":
    for refInfo in output.strip().split("\n"):
      let s = refInfo.strip().split("|")
      if s.len < 2:
        echo "failed to get log for: ", pkg
        return
      if s[1] != "":
        pkg.versions.add Version(
          hash: s[0], time: fromUnix(parseInt(s[2])), tag: s[1].replace("tag: ", "")
        )
  pkg.status = UpToDate
  removeDir(pkg.repo.path)

proc hgUpdateVersions(pkg: var NimPackage) =
  ## mercurial repos are officially supported,
  ## but all existing packages are tagged deleted.
  raise newException(NimPkgCrawlerError, "hg support has not been implemented")

proc updateVersions*(pkg: var NimPackage) =
  case pkg.`method`
  of "git":
    gitUpdateVersions pkg
  of "hg":
    hgUpdateVersions pkg

proc `|=`*(b: var bool, x: bool) =
  b = b or x

proc clearExtras(p: NimPackage): NimPackage =
  result = p
  result.lastCommitHash = ""
  result.lastCommitTime = Time()
  result.status = Unknown

proc dump*(p: NimPackage, dir: string) =
  writeFile(dir / p.name & ".json", p.clearExtras().toJson().fromJson().pretty())

proc recent*(r: seq[Remote]): Remote =
  if r.len == 0:
    raise newException(ValueError, "remotes is length 0")
  r[0]

proc parseRemotes*(remoteStr: string): seq[Remote] =
  for line in remoteStr.strip().split("\n"):
    # TODO: warn me or log it?
    if line.startswith("warning"):
      continue
    let s = line.strip().split("\t")
    if s.len != 2:
      continue
    result.add Remote(hash: s[0], `ref`: s[1])

# TODO: this could be Result[bool, string] to continue (with an optional --continue flag to ignore errors?)
proc checkRemotes*(np: var NimPackage): bool =
  if np.status in Alias..Deleted: return # nothing to check for these...
  let (remoteResponse, code) = execCmdEx(fmt"git ls-remote {np.repo.url}", env = gitEnv)
  # TODO: replace with Result to propagate up these errors
  if code != 0:
    np.status = Unreachable
    if remoteResponse.startswith("fatal: could not read Username") or
        remoteResponse.strip().endsWith("not found") or
        ("Could not resolve host:" in remoteResponse) or
        ("SSL certificate problem" in remoteResponse) or
        ("The requested URL returned error: 502" in remoteResponse):
      return
    else:
      quit "\n\nunexpected result parsing below:\n" & remoteResponse & "\nfor package: " & $np

  let recentRemote = parseRemotes(remoteResponse).recent()
  if np.lastCommitHash != recentRemote.hash:
    np.status = OutOfDate
    result = true
    np.lastCommitHash = recentRemote.hash

const nimlangPackageUrl =
  "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"

proc fetchPackageJson(): string =
  var client = newHttpClient()
  try:
    result = client.get(nimLangPackageUrl).body()
  finally:
    close client

proc cmpPkgs*(a, b: Package): int =
  cmp(toLowerAscii(a.name), toLowerAscii(b.name))

proc getOfficialPackages*(): (Remote,seq[Package]) =
  let
    (remoteResponse, code) = execCmdEx(fmt"git ls-remote https://github.com/nim-lang/packages", env = gitEnv)
  if code != 0:
    errQuitWithCode code, "failed to get nim-lang/packages revision"
  let packagesRev = remoteResponse.parseRemotes().recent()
  var packages = fetchPackageJson().fromJson(seq[Package])
  packages.sort(cmpPkgs)
  return (packagesRev, packages)

proc initNimPkgs(path: string): NimPkgs =
  if fileExists path:
    result = readFile(path).fromJson(typeof(result))

proc `*`(p: Package): NimPackage =
  ## generate a NimPackage anew
  result <- p

proc `[]`(np: var NimPkgs, p: Package): var NimPackage =
  np.packages[p.name]

proc `<-`(np: var NimPkgs, p: Package) =
  if p notin np:
    np.add *p
  elif np[p].url != p.url:
    np.add *p

proc `[]`*(np: var NimPkgs, name: string): var NimPackage =
  np.packages[name]

proc newNimPkgs*(path: string): Nimpkgs =
  result = initNimPkgs(path)
  let (rev, officialPackages) = getOfficialPackages()
  result.packagesHash = rev.hash
  for p in officialPackages:
    result <- p

proc gitCmd(cmd: string): string =
  let (output, code) = execCmdEx cmd
  result = output
  if code != 0:
    echo "failed to run cmd: " & cmd
    echo "output\n:" & output
    quit 1

func packageFilesFromGitOutput(output: string): seq[string] =
  output.splitLines().filterIt(it.startsWith("packages/"))

proc recentPackages(existing: seq[string]): seq[string] =
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

proc setRecent*(nimpkgs: var  NimPkgs) =
  nimpkgs.recent = recentPackages(nimpkgs.packages.keys.toSeq())

proc getOutOfDatePackages*(nimpkgs: NimPkgs): seq[string] =
  for name, pkg in nimpkgs.packages.pairs():
    if pkg.status in Unknown..OutOfDate:
      result.add name

proc getValidPackages*(nimpkgs: NimPkgs): seq[string] =
  for name, pkg in nimpkgs.packages.pairs():
    if pkg.status notin Alias..Deleted:
      result.add name


