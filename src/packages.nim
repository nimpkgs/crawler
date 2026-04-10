import std/[
  algorithm, httpclient, options, os, sequtils, sets, strformat,
  strtabs, strutils, sugar, tables, tempfiles, times, uri
]
import chronos, jsony
import chronos/[asyncproc, asyncsync]
import stew/byteutils
from std/json import pretty
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

  Commit* = object
    hash: string
    time: int # unix timestamp

  Version = object
    tag*, hash*: string
    time*: int

  Package* = object
    name*, url*, `method`*, description*: string
    license*, web*, doc*, alias*: string
    tags*: seq[string]

  GitRepo = object
    url*, path*: string

  # Should the default status actually be UpToDate?
  NimPackageStatus* = enum
    Valid,
    Unknown,
    Unreachable,
    Deleted

  NimbleVersion = object
    kind: string # enum?
    ver: string
  NimbleRequire = object
    name: string
    str: string
    ver: NimbleVersion
  NimbleDump = object
    version*: string
    requires*: seq[NimbleRequire]
    bin*: seq[string]
    srcDir*: string
    # paths*: seq[string] # do I actually need these
    # some combo of install and src is probably necessary to determine if it's a library or an executable/hybrid

  NimPackageMeta = object
    nimble: Option[NimbleDump]
    broken: bool
    hasBin: bool
    versions*: seq[Version]
    commit*: Commit
    status*: NimPackageStatus
    versionTime*: int ## index only value
    commitTime*: int ## index only value
    # deps: RawJson

  NimPackage* = object
    name*, url*, `method`*, description*,
      license*, web*, doc*, alias*: string
    tags*: seq[string]
    meta*: NimPackageMeta

  NimPkgs* = OrderedTable[string, NimPackage]

  CheckResult* = object
    hasNewCommits*: bool
    pkg*: NimPackage
    err*: string  ## non-empty when lsRemote failed with an unrecognized pattern

proc info*(pkg: NimPackage, args: varargs[string, `$`]) =
  info pkg.name.bb("bold"), " | ", args.join(" ")
proc debug*(pkg: NimPackage, args: varargs[string, `$`]) =
  debug pkg.name.bb("bold"), " | ", args.join(" ")

proc pkgPrefix(name: string): string =
  if name.len < 2:
    # one letter .... what a great name for a package >:(
    return (name & "_").toLowerAscii()
  name[0..1].toLowerAscii()

proc pkgPath*(name: string): string =
  ctx.paths.packages / pkgPrefix(name) / name / "pkg.json"

proc path(p: NimPackage): string =
  pkgPath(p.name)

func isAlias(pkg: NimPackage): bool {.inline.} =
  pkg.alias != ""

func add*(nimpkgs: var NimPkgs, p: NimPackage) =
  nimpkgs[p.name] = p

func noCommitData(np: NimPackage): bool =
  np.meta.commit.time == 0

proc lastCommitTime(np: NimPackage): Time =
  np.meta.commit.time.fromUnix()

proc recentlyUpdated(np: NimPackage, duration = initDuration(days = 7)): bool =
  # TODO: make this configurable with --duration flag?
  (getTime() - np.lastCommitTime) < duration

proc isOutOfDate(p: NimPackage): bool {.inline.} =
  if p.isAlias: return false
  p.noCommitData or p.recentlyUpdated

func setMetadataForIndex*(np: var NimPackage) =
  np.meta.commitTime = np.meta.commit.time
  np.meta.commit = Commit()
  np.method = ""
  np.license = ""
  np.web = ""
  np.doc = ""
  np.meta.nimble = none(NimbleDump)
  if np.meta.versions.len >= 1:
    np.meta.versionTime = np.meta.versions[0].time
    # np.meta.versions = @[np.meta.versions[0]]
    np.meta.versions = @[]

proc postHook*(np: var NimPackage) =
  if "deleted" in np.tags:
    np.meta.status = Deleted
  if np.isAlias:
    np.meta.status = Valid # it works it's just actually an alias

# proc skipHook*(T: typedesc[NimPackage], key: static string): bool =
#   key in ["outOfDate"]

template dumpKey(s: var string, v: string) =
  const v2 = v.toJson() & ":"
  s.add v2


# NOTE: should I just be using optionals instead of these complex isNull things?
# or should Option[T] == None -> also be isNull
proc isNull(v: string): bool = v == ""
proc isNull(v: seq[Version]): bool = v == @[]
proc isNull[T](v: seq[T]): bool = v == newSeq[T]()
proc isNull(v: Time): bool = v == Time()
proc isNull(v: bool): bool = not v
proc isNull[A, B](v: OrderedTable[A, B]): bool =
  v.len() == 0
proc isNull(v: NimPackageStatus): bool =
  v == Valid 
proc isNull(v: Commit): bool = v.hash == "" and v.time == 0
proc isNull(v: int): bool = v == 0
proc isNull(v: RawJson): bool = v.string == ""
proc isNull(v: NimPackageMeta): bool = v == NimPackageMeta()
proc isNull[T](o: Option[T]): bool = o.isNone

proc dumpHook*(s: var string, v: Time) = s.add $v.toUnix()

proc parseHook*(s: string, i: var int, v: var Time) =
  var num: int
  parseHook(s, i, num)
  v = fromUnix(num)

proc dumpHook*(s: var string, v: NimPackage | NimPkgs | NimPackageMeta) =
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
    np.meta.status = Deleted
  else:
    np.meta.status = Unknown

proc `<-`*(np: var NimPackage, p: Package) {.inline.} = map np, p

func mapPkgErr*[T](self: R[T], name: string): R[T] {.inline.} =
  self.prependError(fmt"failure for package, {name}")

# NOTE: this command is used repeatedly would it be better to attach and delete later?
proc repo(pkg: NimPackage): GitRepo =
  assert not pkg.isAlias
  result.url =
    if "?subdir=" in pkg.url: pkg.url.split("?subdir=")[0]
    else: pkg.url
  let s = result.url.strip(chars={'/'}, leading=false).split("/")
  result.path = "repos" / s[^2..^1].join("-") & ".git"

proc extractSubDir(u: Uri): R[string] =
  for k, v in u.query.decodeQuery():
    if k == "subdir":
      return ok v
  err fmt"failed to extract subdir from url: {u}"

proc nimbleWorkingDir(pkg: NimPackage): R[string] =
  let repo = pkg.repo
  if "subdir" in pkg.url:
    let subDir = ?parseUri(pkg.url).extractSubdir()
    ok repo.path / subDir
  else:
    ok repo.path

proc runCmd(cmd: string, workingDir = "",
            env: StringTableRef = nil): Future[CommandExResponse] {.async.} =
  ## Run a command, merging stderr into stdout (matches execCmdEx behavior).
  let p = await startProcess(cmd, workingDir = workingDir, environment = env,
    options = {AsyncProcessOption.EvalCommand, AsyncProcessOption.StdErrToStdOut},
    stdoutHandle = AsyncProcess.Pipe)
  let outR = p.stdoutStream.read()
  try:
    let status = await p.waitForExit(InfiniteDuration)
    result = CommandExResponse(
      status: status,
      stdOutput: string.fromBytes(await outR),
      stdError: "")
  finally:
    await p.closeWait()

proc cmdResult(cmd: string, workingDir = ""): Future[R[string]] {.async.} =
  debug bbfmt"[faint]cmd: {cmd}"
  let resp = await runCmd(cmd, workingDir = workingDir)
  if resp.status != 0:
    return err fmt"cmd: `{cmd}` failed with exit code {resp.status}".appendError(resp.stdOutput)
  ok resp.stdOutput

proc git(cmd: string): Future[CommandExResponse] {.async.} =
  debug bbfmt"[faint]cmd: git {cmd}"
  var env: StringTableRef
  {.cast(gcsafe).}: env = gitEnv
  return await runCmd(fmt"git {cmd}", env = env)

proc gitResult(cmd: string): Future[R[string]] {.async.} =
  let resp = await git(cmd)
  if resp.status != 0:
    return err fmt"cmd: `git {cmd}` failed with exit code {resp.status}".appendError(resp.stdOutput)
  ok resp.stdOutput.strip()

proc processGitShow(showOutput: string): R[Commit] =
  var filtered: seq[string]
  for l in showOutput.strip().splitLines():
    if l.startsWith("warning"):
      if l.startsWith("warning: redirecting"):
        continue
      else:
        return err fmt"unknown warning from git: `{l}`"
    else: filtered.add l
  if filtered.len != 1:
    return err fmt"unexpected number of lines, expected 1, got: {filtered}"
  let s = filtered[0].strip().split("|")
  if s.len != 2:
    return err fmt"expected sequence of len 2, got: {s}"

  attempt(fmt"failed to parse time as integer: `{s[1]}`"):
    return ok Commit(hash: s[0], time: parseInt(s[1]))

proc setLastestCommit(pkg: NimPackage): Future[R[NimPackage]] {.async.} =
  var p = pkg
  let errMsgPrefix = fmt"failed to get most recent commit from local repo, {p.repo.path}"
  let output =
    ?(await gitResult(fmt"-C {p.repo.path} show {p.meta.commit.hash} --format='%H|%ct' -s"))
    .prependError(errMsgPrefix)
  p.meta.commit =
    ?processGitShow(output)
    .prependError(errMsgPrefix)
  ok(p)

proc log(repo: GitRepo): Future[R[string]] {.async.} =
  let cmd =
    fmt"-C {repo.path} log --format='%H|%D|%ct'" &
    " --decorate-refs='refs/tags/v*.*' --decorate-refs='refs/tags/*.*.*' --tags --no-walk"
  return await gitResult(cmd)

proc clone(pkg: NimPackage): Future[E] {.async.} =
  # TODO: attach repo to the package and use in skipHook?
  let repo = pkg.repo
  if not dirExists repo.path:
    discard
      ?(await gitResult(fmt"clone {repo.url} {repo.path}"))
      .prependError(fmt"failed to clone {repo.url} to {repo.path}")
    ok()
  else:
    discard ?(await gitResult(fmt"-C {repo.path} fetch origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' --prune"))
      .prependError(fmt"failed to update local repo at {repo.path}")
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
    attempt"failed to parse versions":
      if info[1] != "":
        vs.add Version(
          hash: info[0],
          time: parseInt(info[2]),
          tag: info[1].replace("tag: ", "")
        )
  ok vs

proc getNimbleDump(pkg: NimPackage): Future[R[NimPackage]] {.async.} =
  # for now use the git checkout of HEAD
  # TODO: abstract the nimble command to always use --useSystemNim and --nimbleDir:(absolute-path)
  # TODO: parse seperately the following 'Error:  Could not find a file with a .nimble extension inside the specified directory:'
  var p = pkg
  let wd = ?p.nimbleWorkingDir
  let dumpOutput = ?(await cmdResult("nimble dump --nimbleDir:../../nimbleDir --useSystemNim --json", workingDir = wd))
  # broken != a missing nimble file
  # preseve the "nimble error"
  let parsedDump = ?fromJsonResult(dumpOutput, NimbleDump)
  p.meta.nimble = some(parsedDump)

  if parsedDump.bin.len > 0:
    p.meta.hasBin = true

  ok(p)

# proc getNimbleDeps(pkg: var NimPackage): E =
#   # BUG: nimble deps must be run from within the working dir
#   let depsOutput = ?cmdResult(fmt"nimble deps {pkg.repo.path} --nimbleDir:nimbleDir --useSystemNim --format:json")
#   pkg.meta.deps = ?fromJsonResult(depsOutput, RawJson)
#   ok()

proc getNimbleMeta(pkg: NimPackage): Future[R[NimPackage]] {.async.} =
  var p = pkg
  debug p, "getting nimble dump data"
  if p.meta.versions.len != 0:
    let latest = p.meta.versions[0].hash
    discard ?(await gitResult(fmt"-C {p.repo.path} checkout {latest}"))
  let dumped = await getNimbleDump(p)
  if dumped.isOk:
    p = dumped.get()
  else:
    p.meta.broken = true
    error p.name, " is not a working package see error: ", dumped.error()
  ok(p)

  # ?getNimbleDeps(pkg)

# NOTE updating metadata should be it's own seperate proc executed if this one returns true.
proc gitUpdateVersions(pkg: NimPackage): Future[R[NimPackage]] {.async.} =
  var p = pkg
  debug p, "checking for new tags"
  let versions = p.meta.versions
  p.meta.versions = @[]
  ?(await clone(p))
  p = ?(await setLastestCommit(p))
  let output = ?(await p.repo.log())
  if output != "":
    p.meta.versions = ?parseVersionsFromLog(output)
  if not p.meta.broken and (versions != p.meta.versions or p.meta.versions.len == 0):
    p = ?(await getNimbleMeta(p))

  # if i just make context a global this is more straightforward to handle
  # removeDir(p.repo.path)
  ok(p)


proc hgUpdateVersions(pkg: NimPackage): Future[R[NimPackage]] {.async.} =
  ## mercurial repos are officially supported,
  ## but all existing packages are tagged deleted.
  return err "mercurial repositories are not currently supported"

proc updateVersions*(pkg: NimPackage): Future[R[NimPackage]] {.async.} =
  case pkg.`method`
  of "git":
    return await gitUpdateVersions(pkg)
  of "hg":
    return await hgUpdateVersions(pkg)
  else:
    return err "missing method"


proc `|=`*(b: var bool, x: bool) =
  b = b or x

proc clearMetadata(p: NimPackage): NimPackage =
  ## clears unneeded metadata for writing to packages/na/name/pkg.json
  result = p
  result.meta.commitTime = 0
  result.meta.versionTime = 0

proc toPrettyJson(p: NimPackage): string =
  ## roundtrip jsony serialization and std/json deserialization to get pretty string
  p.toJson().fromJson().pretty()

proc dump*(p: NimPackage) =
  createDir p.path.splitFile.dir
  writeFile(p.path, p.clearMetadata().toPrettyJson())

proc parseRemoteRefs(remoteStr: string): seq[Remote] =
  for line in remoteStr.strip().split("\n"):
    # TODO: warn me or log it?
    if line.startswith("warning"):
      continue
    let s = line.strip().split("\t")
    if s.len != 2:
      continue
    result.add Remote(hash: s[0], `ref`: s[1])

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

  # a non-exhaustive list of response that make me mark something unreachable and move on with my life
  # The biggest recurring problem is notabug.org gives a different error every week...
  test response.startswith("fatal: could not read Username")
  test response.strip().endsWith("not found")
  test ("Could not resolve host:" in response)
  test ("SSL certificate problem" in response)
  test ("SSL certificate OpenSSL verify result" in response)
  test ("The requested URL returned error: 502" in response)
  test ("TLS connect error" in response)
  test ("The requested URL returned error: 504" in response)
  test ("Failed to connect to" in response) # gitlab.3dicc.com

  err "unable to interpret git ls-remote, see below:\n" & response.strip()

proc lsRemote(r: GitRepo): Future[CommandExResponse] {.async.} =
  return await git(fmt"ls-remote {r.url}")

proc compare(np: NimPackage, remote: Remote): (bool, NimPackage) =
  var p = np
  if p.meta.commit.hash == remote.hash and p.meta.commit.time != 0:
    return (false, p)
  p.meta.commit = Commit(hash: remote.hash)
  return (true, p)

proc checkRemotes*(pkg: NimPackage): Future[R[CheckResult]] {.async.} =
  ## if hasNewCommits is true the package has new remotes
  var p = pkg
  if p.meta.status in {Unreachable, Deleted} or p.isAlias:
    return ok CheckResult(hasNewCommits: false, pkg: p)
  let resp = await p.repo.lsRemote()
  if resp.status != 0:
    p.meta.status = Unreachable
    let lsRemoteErr =
      remoteIsUnreachable(resp.stdOutput).errorOr("")
    return ok CheckResult(hasNewCommits: false, pkg: p, err: lsRemoteErr)
  p.meta.status = Valid
  let remote = ?recentRemote(resp.stdOutput)
  let (hasNew, updatedPkg) = compare(p, remote)
  ok CheckResult(hasNewCommits: hasNew, pkg: updatedPkg)

proc fetchPackageJson(hash: string): R[string] =
  let url =
    fmt"https://raw.githubusercontent.com/nim-lang/packages/{hash}/packages.json"
  var client = newHttpClient()
  try:
    return ok(client.get(url).body())
  except:
    return err("failed to fetch official packages.json")
  finally:
    close client

proc cmpPkgs*(a:string, b: string): int =
  cmp(toLowerAscii(a), toLowerAscii(b))

proc cmpPkgs*(a, b: Package): int =
  cmpPkgs(a.name, b.name)

proc getOfficialHead*(): Future[R[Remote]] {.async.} =
  let repo = GitRepo(url: "https://github.com/nim-lang/packages")
  let resp = await repo.lsRemote()
  if resp.status != 0:
    return err "failed to get nim-lang/packages revision".appendError(resp.stdOutput)
  recentRemote(resp.stdOutput).prependError("couldn't get remote ref for official packages")

proc getOfficialPackages*(hash: string): R[seq[Package]] =
  var packages = ?fromJsonResult(?fetchPackageJson(hash), seq[Package])
  packages.sort(cmpPkgs)
  ok packages

proc toNimPackage(p: Package): NimPackage =
  ## generate a NimPackage anew
  result <- p

proc loadFromExisting(pkg: var NimPackage): R[void] =
  if fileExists(pkg.path):
    attempt(fmt"failed to load existing metadata for package: {pkg.name}"):
      let existing = fromJson(readFile(pkg.path), NimPackage)
      pkg.meta = existing.meta
      pkg.license = existing.license
      pkg.method = existing.method

  ok()

proc newNimPkgs*(ctx: CrawlerContext, officialPackages: seq[Package]): R[NimPkgs] =
  var nimpkgs = NimPkgs()
  for p in officialPackages:
    var pkg = p.toNimPackage
    ?loadFromExisting(pkg)
    nimpkgs.add pkg
  ok nimpkgs


template withTmpDir(body: untyped) =
  var tmpd {.inject}: string
  try:
    tmpd = createTempDir("nimpkgs_", "")
    body
  finally:
    # TODO: add a debug mode where we don't delete it?
    removeDir(tmpd)

proc getRecentlyAdded*(rev: string, start: seq[Package]): Future[R[seq[string]]] {.async.} =
  var n = 1
  var recent: seq[string]
  var current = start.mapIt(it.name).toHashSet()
  debug "fetching official repo to update recent packages"
  withTmpDir:
    discard ?(await gitResult(fmt"clone https://github.com/nim-lang/packages {tmpd}"))
    while recent.len < 10:
      debug fmt"recent fetch | iter: {n}"
      let output = ?(await gitResult(fmt"-C {tmpd} show {rev}~{n}:packages.json"))
      let prev = ?output.fromJsonResult(seq[Package]).map(pkgs => pkgs.mapIt(it.name).toHashSet())
      let new = current - prev
      for n in new:
        recent.add n
      current = prev; inc n
  ok(recent)

proc lastReleaseTime(pkg: NimPackage): int =
  if pkg.meta.versions.len > 0:
    result = pkg.meta.versions[0].time

proc sortedByVersionRelease(pkgs: seq[NimPackage], order = Descending): seq[NimPackage] =
  proc cmpVersion(p1, p2: NimPackage): int =
    cmp(p1.lastReleaseTime, p2.lastReleaseTime)
  result = pkgs.sorted(cmpVersion, order = order)

proc getRecentlyReleased*(nimpkgs: NimPkgs): OrderedTable[string, string] =
  let sortedPkgs = nimpkgs.values().toSeq().sortedByVersionRelease()
  for pkg in sortedPkgs[0..10]:
    result[pkg.name] = pkg.meta.versions[0].tag

proc getOutOfDatePackages*(nimpkgs: NimPkgs): seq[string] =
  for name, pkg in nimpkgs.pairs():
    if pkg.meta.status in {Valid, Unknown} and pkg.isOutOfDate:
      result.add name

proc getValidPackages*(nimpkgs: NimPkgs): seq[string] =
  for name, pkg in nimpkgs.pairs():
    if pkg.meta.status notin {Unreachable, Deleted} and not pkg.isAlias:
      result.add name

proc getUnreachablePackages*(nimpkgs: NimPkgs): seq[string] =
  for name, pkg in nimpkgs.pairs():
    if pkg.meta.status == Unreachable:
      result.add name

proc getUnknownPackages*(nimpkgs: NimPkgs): seq[string] =
  for name, pkg in nimpkgs.pairs():
    if pkg.meta.status == Unknown:
      result.add name
