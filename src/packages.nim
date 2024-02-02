import std/[
    httpclient, strformat, strutils,
    options, osproc, os,
    sets, strtabs, tables, times
]
from std/json import pretty

import jsony

import progress

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

  NimPackage* = object
    name*, url*, `method`*, description*, license*, web*, doc*, alias*: string
    lastCommitHash*: string
    lastCommitTime*: Time
    versions*: seq[Version]
    tags*: seq[string]
    deleted*: bool
    outOfDate*: bool

  NimPkgs* = object
    updated*: Time
    packagesHash*: string
    packages*: OrderedTable[string, NimPackage]

proc addPkg*(nimpkgs: var NimPkgs, p: NimPackage) =
  nimpkgs.packages[p.name] = p

proc postHook*(np: var NimPackage) =
  np.outOfDate = (
    (getTime() - np.lastCommitTime) < initDuration(days = 7) or (
      np.lastCommitTime == fromUnix(0)
    )
  )

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
proc dumpHook(s: var string, v: Time) = s.add $v.toUnix()

proc parseHook*(s: string, i: var int, v: var Time) =
  var num: int
  parseHook(s, i, num)
  v = fromUnix(num)

proc dumpHook*(s: var string, v: NimPackage | NimPkgs) =
  s.add '{'
  var i = 0
  for k, e in v.fieldPairs:
    when compiles(skipHook(type(v), k)):
      when skipHook(type(v), k):
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

proc `<-`*(np: var NimPackage, p: Package) {.inline.} = map np, p

proc repo(pkg: NimPackage): tuple[url: string, path: string] =
  result.url =
    if "?subdir=" in result.url: pkg.url.split("?subdir=")[0]
    else: pkg.url
  let s = result.url.split("/")
  result.path = "repos" & s[^2..^1].join("-") & ".git"


proc gitLastestCommit*(pkg: var NimPackage) =
  let (output, code) =
    execCmdEx(
      fmt"git --git-dir={pkg.repo.path} show --format='%H|%ct' -s",
      options = {poUsePath},
    )
  if code != 0:
    echo output
    echo fmt"error fetching last commit"
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
    echo fmt"error fetching history"
  return output

proc gitClone*(pkg: NimPackage) =
  let (url, path) = pkg.repo()
  if not dirExists path:
    let (_, errCode) = execCmdEx fmt"git clone --filter=tree:0 --bare {url} {path}"
    if errCode != 0:
      echo fmt"error cloning {pkg.name}"

proc gitUpdateVersions(pkg: var NimPackage, pb: var ProgressBar) =
  # TODO: update to only go as deep as necessary with clone
  pkg.gitClone
  pkg.versions = @[]
  pkg.gitLastestCommit
  let output = pkg.gitLog
  if output != "":
    for refInfo in output.strip().split("\n"):
      let s = refInfo.strip().split("|")
      if s.len < 2:
        echo "failed to get log for: ", pkg
        pb.echo "ERROR-----"
        pb.echo output
        pb.echo "ERROR-----"
        return
      if s[1] != "":
        pkg.versions.add Version(
          hash: s[0], time: fromUnix(parseInt(s[2])), tag: s[1].replace("tag: ", "")
        )
  removeDir(pkg.repo.path)

proc hgUpdateVersions(pkg: var NimPackage, pb: var ProgressBar) =
  ## mercurial repos are officially supported,
  ## but all existing packages are tagged deleted.
  raise newException(NimPkgCrawlerError, "hg support has not been implemented")

proc updateVersions*(pkg: var NimPackage, pb: var ProgressBar) =
  case pkg.`method`
  of "git":
    pkg.gitUpdateVersions(pb)
  of "hg":
    pkg.hgUpdateVersions(pb)

proc `|=`(b: var bool, x: bool) = b = b or x

proc isInvalid*(pkg: NimPackage): bool =
  if "deleted" in pkg.tags:
    result |= true
  if pkg.`method` == "hg":
    result |= true
  if pkg.alias != "":
    result |= true

proc clearExtras(p: NimPackage): NimPackage =
  result = p
  result.lastCommitHash = ""
  result.lastCommitTime = Time()
  result.deleted = false

proc dump*(p: var NimPackage, dir: string) =
  writeFile(dir / p.name & ".json", p.clearExtras().toJson().fromJson().pretty())

proc recent*(r: seq[Remote]): Remote =
  if r.len == 0:
    echo "OH NO"
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

proc checkRemotes*(np: var NimPackage, pb: var ProgressBar): bool =
  pb.status fmt"checking {np.name} for updated commits"
  let (remoteResponse, code) = execCmdEx(fmt"git ls-remote {np.repo.url}", env = gitEnv)
  if code != 0:
    if remoteResponse.startswith("fatal: could not read Username") or
        remoteResponse.strip().endsWith("not found"):
      np.deleted = true
  else:
    let remotes = remoteResponse.parseRemotes
    let recentRemote = recent(remotes)
    if np.lastCommitHash != recentRemote.hash:
      result = true
      np.lastCommitHash = recentRemote.hash


