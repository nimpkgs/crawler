import std/[
    algorithm, httpclient, options,
    os, osproc, sequtils,
    sets, strformat, strtabs,
    strutils, tables, times,
]
from std/json import pretty
import jsony, results
export results
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
  Remote* = object
    hash*, `ref`*: string

  Commit = object
    hash: string
    time: Time

  Version = object
    tag*, hash*: string
    time*: Time

  Package* = object
    name*, url*, `method`*, description*: string
    license*, web*, doc*, alias*: string
    tags*: seq[string]

  GitRepo = object
    url*, path*: string

  NimPackageStatus* = enum # order matters here since ranges are used
    Unknown,
    OutOfDate,
    UpToDate,
    Unreachable,
    Alias,
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

  R[T] = Result[T, string] # all errors used should be simple strings

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
  if np.status in {Unreachable, Alias, Deleted}:
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

func mapPkgErr*[T](self: R[T], name: string): R[T] {.inline.} =
  self.prependError(fmt"failure for package, {name}")

proc repo(pkg: NimPackage): GitRepo =
  result.url =
    if "?subdir=" in pkg.url: pkg.url.split("?subdir=")[0]
    else: pkg.url
  let s = result.url.split("/")
  result.path = "repos" / s[^2..^1].join("-") & ".git"

proc git(cmd: string): tuple[output: string, exitCode: int] =
  result = execCmdEx(fmt"git {cmd}", env = gitEnv)


proc latestCommit(repo: GitRepo): R[Commit] =
  let (output, code) = git(fmt"--git-dir={repo.path} show --format='%H|%ct' -s")
  let s = output.strip().split("|")
  if code != 0 or s.len != 2:
    return err fmt"failed to get most recent commit from local repo {repo.path}, see below".appendError(output)
  try:
    ok Commit(hash: s[0], time: fromUnix(parseInt(s[1])))
  except:
    err fmt"failed to parse time: `{s[1]}`"


proc setLastestCommit(pkg: var NimPackage): R[void] =
  let commit = ?pkg.repo.latestCommit()
  pkg.lastCommitHash = commit.hash
  pkg.lastCommitTime = commit.time
  ok()

# should these git commands be gitAsResult?

proc log(repo: GitRepo): R[string] =
  let cmd =
    fmt"--git-dir={repo.path} log --format='%H|%D|%ct'" &
    " --decorate-refs='refs/tags/v*.*' --tags --no-walk"
  let (output, code) = git(cmd)
  if code != 0:
    return err "git log failed, see output below".appendError(output)
  ok output

proc clone(repo: GitRepo): R[void] =
  # BUG: doesn't properly handle case where repo already exists
  if not dirExists repo.path:
    let (output, code) = git(fmt"clone --filter=tree:0 --bare {repo.url} {repo.path}")
    if code != 0:
      return err fmt"failed to clone {repo.url} to {repo.path}, see output below".appendError(output)
  ok()

proc splitLine(line: string): R[array[3, string]] =
  let s = line.strip().split("|")
  if s.len != 3:
    return err fmt"failed to parse version from line: {line}"
  result.ok [s[0], s[1], s[2]]

proc parseVersionsFromLog(log: string): R[seq[Version]] =
  var vs: seq[Version]
  for line in log.strip.splitLines:
    let info = ?line.splitLine()
    try:
      if info[1] != "":
        vs.add Version(
          hash: info[0],
          time: fromUnix(parseInt(info[2])),
          tag: info[1].replace("tag: ", "")
        )
    except:
      return err "failed to parse versions" & getCurrentExceptionMsg()
  ok vs

proc gitUpdateVersions(pkg: var NimPackage): R[void] =
  pkg.versions = @[]
  ?pkg.repo.clone()
  ?pkg.setLastestCommit
  let output = ?pkg.repo.log()
  if output != "":
    pkg.versions = ?parseVersionsFromLog(output)
  pkg.status = UpToDate
  removeDir(pkg.repo.path)
  ok()

proc hgUpdateVersions(pkg: var NimPackage): R[void] =
  ## mercurial repos are officially supported,
  ## but all existing packages are tagged deleted.
  return err "mercurial repositories are not currently supported"

proc updateVersions*(pkg: var NimPackage): R[void] =
  case pkg.`method`
  of "git":
    result = gitUpdateVersions pkg
  of "hg":
    result = hgUpdateVersions pkg

proc `|=`*(b: var bool, x: bool) =
  b = b or x

proc clearExtras(p: NimPackage): NimPackage =
  result = p
  result.lastCommitHash = ""
  result.lastCommitTime = Time()
  result.status = Unknown

proc dump*(p: NimPackage, dir: string) =
  writeFile(dir / p.name & ".json", p.clearExtras().toJson().fromJson().pretty())

proc parseRemoteRefs(remoteStr: string): seq[Remote] =
  for line in remoteStr.strip().split("\n"):
    # TODO: warn me or log it?
    if line.startswith("warning"):
      continue
    let s = line.strip().split("\t")
    if s.len != 2:
      continue
    result.add Remote(hash: s[0], `ref`: s[1])

proc recentRemote(np: NimPackage, response: string): R[Remote] =
  let remotes = parseRemoteRefs(response)
  if remotes.len != 0:
    return ok remotes[0]
  err "could not parse remote refs from git ls-remote: \n" & response

proc recentRemote(response: string): R[Remote] =
  let remotes = parseRemoteRefs(response)
  if remotes.len != 0:
    return ok remotes[0]
  err "could not parse remote refs from git ls-remote: \n" & response

proc remoteIsUnreachable(response: string): R[bool] =
  ## false in this context is for the caller,
  ## returning false is for an expected case in which the repo is considered unreachable
  template test(cond: bool) =
    if cond: return ok false

  test response.startswith("fatal: could not read Username")
  test response.strip().endsWith("not found")
  test ("Could not resolve host:" in response)
  test ("SSL certificate problem" in response)
  test ("The requested URL returned error: 502" in response)
  test ("TLS connect error" in response)

  err "unable to interpret git ls-remote, see below:\n" & response.strip()

proc lsRemote(r: GitRepo): tuple[output: string, exitCode: int] =
  result = git(fmt"ls-remote {r.url}")

proc compare(np: var NimPackage, remote: Remote): bool =
  if np.lastCommitHash == remote.hash:
    np.status = UpToDate
    return

  np.status = OutOfDate
  np.lastCommitHash = remote.hash
  return true

proc checkRemotes*(np: var NimPackage): R[bool] =
  if np.status in Alias..Deleted:
    return ok false # nothing to check for these so noop...
  let (lsRemoteOutput, code) = np.repo.lsRemote()
  if code != 0:
    np.status = Unreachable
    return remoteIsUnreachable(lsRemoteOutput)
  let remote = ?recentRemote(lsRemoteOutput)
  ok compare(np, remote)

const nimlangPackageUrl =
  "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"

proc fetchPackageJson(): string =
  var client = newHttpClient()
  try:
    result = client.get(nimLangPackageUrl).body()
  finally:
    close client

proc cmpPkgs*(a:string, b: string): int =
  cmp(toLowerAscii(a), toLowerAscii(b))

proc cmpPkgs*(a, b: Package): int =
  cmpPkgs(a.name, b.name)

# TODO: bubble up an error?
proc getOfficialPackages*(): (Remote,seq[Package]) =
  let repo = GitRepo(url: "https://github.com/nim-lang/packages")
  let
    (remoteResponse, code) = repo.lsRemote()
  if code != 0:
    errQuitWithCode code, "failed to get nim-lang/packages revision: \n" & remoteResponse
  let packagesRev = recentRemote(remoteResponse).expect("couldn't get remote ref for official packages")
  var packages = fetchPackageJson().fromJson(seq[Package])
  packages.sort(cmpPkgs)
  return (packagesRev, packages)

proc initNimPkgs(path: string): R[NimPkgs] =
  if fileExists path:
    try:
      return ok readFile(path).fromJson(NimPkgs)
    except:
      return err "failed to load existing nimpkgs, see below".appendError(getCurrentExceptionMsg())

  ok NimPkgs()


proc `*`(p: Package): NimPackage =
  ## generate a NimPackage anew
  result <- p

proc `[]`(np: var NimPkgs, p: Package): var NimPackage =
  np.packages[p.name]

proc `<-`(np: var NimPkgs, p: Package) =
  if p notin np:
    np.add *p
  # a new url means new commits/tags
  elif np[p].url != p.url:
    np.add *p

proc `[]`*(np: var NimPkgs, name: string): var NimPackage =
  np.packages[name]

proc newNimPkgs*(ctx: CrawlerContext): R[Nimpkgs] =
  var nimpkgs = ?initNimPkgs(ctx.paths.nimpkgs)
  let (rev, officialPackages) = getOfficialPackages()
  nimpkgs.packagesHash = rev.hash
  for p in officialPackages:
    # TODO: handle unknown names
    if p.name in ctx.force:
      nimpkgs.add *p
    else:
      nimpkgs <- p

  ok nimpkgs

func packageFilesFromGitOutput(output: string): seq[string] =
  output.splitLines().filterIt(it.startsWith("packages/"))


proc gitAsResult(cmd: string): R[string] =
  let (output, code) = git(cmd)
  if code != 0:
    return err fmt"cmd: `git {cmd}` failed, see output".appendError(output)
  ok output

# Result?
proc recentPackages(existing: seq[string]): R[seq[string]] =
  ## brute force attempt to establish the most recent packages added to packages.json
  let lsFilesOutput = ?gitAsResult("ls-files --others --exclude-standard")
  let logOutput = ?gitAsResult("log --pretty'' --name-only")
  var paths = packageFilesFromGitOutput(lsFilesOutput & logOutput)
  # why am I reversing twice?
  paths.reverse()
  paths = paths
    .toOrderedSet()
    .toSeq()[^10..^1]
    .mapIt(it.replace("packages/","")
    .replace(".json",""))
    .filterIt(it in existing)
  paths.reverse()
  ok paths

proc setRecent*(nimpkgs: var  NimPkgs): R[void] =
  nimpkgs.recent = ?recentPackages(nimpkgs.packages.keys.toSeq())
  ok()

proc getOutOfDatePackages*(nimpkgs: NimPkgs): seq[string] =
  for name, pkg in nimpkgs.packages.pairs():
    if pkg.status in Unknown..OutOfDate:
      result.add name

proc getValidPackages*(nimpkgs: NimPkgs): seq[string] =
  for name, pkg in nimpkgs.packages.pairs():
    if pkg.status notin {Unreachable, Alias, Deleted}:
      result.add name

proc getUnreachablePackages*(nimpkgs: NimPkgs): seq[string] =
  for name, pkg in nimpkgs.packages.pairs():
    if pkg.status == Unreachable:
      result.add name
