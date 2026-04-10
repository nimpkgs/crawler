import std/strutils
import hwylterm, jsony, results
import hwylterm/logging
export hwylterm, jsony, logging, results

setHwylConsoleFile(stderr)

type
  R*[T] = Result[T, string] # all errors used should be simple strings
  E* = R[void]

  Paths* = object
    index* = "./nimpkgs.json"
    packages* = "./packages"

  Jobs* = object
    remote*: int = 50
    fetch*: int = 10

  CrawlerContext* = object
    paths*: Paths
    force*, check*: seq[string]
    jobs*: Jobs

var ctx* = CrawlerContext()

iterator splitLinesFinal(s: string): tuple[line: string, final: bool] =
  let lines = s.strip().splitLines(keepEol = true)
  for i, line in lines:
    yield (line: line, final: i == lines.high)

proc appendError*(s1, s2: string; count: Natural = 2): string =
  # result.add s1 & ":\n" & indent(s2, count, padding = "│ ")
  result.add s1
  result.add ":\n"
  for (l, final) in s2.splitLinesFinal():
    result.add if final: "╰ " else: "│ "
    result.add l

template attempt*(msg: string, body: untyped) =
  try:
    body
  except:
    return err(msg.appendError(getCurrentExceptionMsg()))

proc fromJsonResult*[T](s: string, x: typedesc[T]): R[T] =
  attempt"json parsing error":
    return ok(fromJson(s, x))

proc prependError*[T, E](self: Result[T,E], s: string): Result[T, E] {.inline.} =
  self.mapErr(proc(e: string): string = s.appendError(e))

proc showError(args: varargs[string, `$`]) =
  writeLine stderr, $bb"[b red]ERROR[/]: ", args.join("")

proc errQuitWithCode*(code: int, args: varargs[string, `$`]) =
  quit $bb"[b red]ERROR[/]: " & args.join(""), code

proc errQuit*(args: varargs[string, `$`]) =
  errQuitWithCode 1, args

proc bail*[T,E](r: Result[T, E], msg: string = ""): T =
  ## behaves similar to expect but quits the program without defect
  if r.isOk:
    when T is not void:
      return r.value
  else:
    # let errVal = r.error() # using Time in packages is causing `$`R to have sideeffects
    let errVal = r.unsafeError
    let prefix = ($bb"[b]UNEXPECTED crawler exit[/]") & (if msg == "": "" else: ", " & msg)
    errQuit prefix.appendError(errVal)

template handleError*(ctx: CrawlerContext, e: string) =
  if ctx.ignoreError:
    #showError(ctx, e)
    error e
  else:
    result = err(e)
    return

addHandler newHwylConsoleLogger(levelThreshold=lvlAll)


