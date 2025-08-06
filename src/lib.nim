import std/[strutils]
import hwylterm, results
export results

type
  Paths* = tuple
    nimpkgs = "./nimpkgs.json"
    packages = "./packages"

  CrawlerContext* = object
    # nimpkgs: NimPkgs
    paths*: Paths
    force*, check*: seq[string]
    ignoreError*: bool

iterator splitLinesFinal(s: string): tuple[line: string, final: bool] =
  let lines = s.strip().splitLines(keepEol = true)
  for i, line in lines:
    yield (line: line, final: i == lines.high)

proc appendError*(s1, s2: string; count: Natural = 2): string =
  # result.add s1 & ":\n" & indent(s2, count, padding = "│ ")
  result.add s1
  result.add ":\n"
  for (l, final) in s2.splitLinesFinal():
    result.add if final: "┴ " else: "│ "
    result.add l
  # result.add "\n"
  # result.add "┴"

proc prependError*[T, E](self: Result[T,E], s: string): Result[T, E] {.inline.} =
  self.mapErr(proc(e: string): string = s.appendError(e))

proc showError*(args: varargs[string, `$`]) =
  writeLine stderr, $bb"[b red]ERROR[/]: ", args.join("")

proc showError*(spinner: Spinny, args: varargs[string, `$`]) =
  spinner.write bb"[b red]ERROR[/]: " & args.join("")

proc errQuitWithCode*(code: int, args: varargs[string, `$`]) =
  writeLine stderr, $bb"[b red]ERROR[/]: ", args.join("")
  quit code

proc errQuit*(args: varargs[string, `$`]) =
  errQuitWithCode 1, args

proc errQuit*(spinner: Spinny, args: varargs[string, `$`]) =
  stop spinner
  errQuitWithCode 1, args

proc bail*[T,E](r: Result[T, E], msg: string = ""): T =
  ## behaves similar to expect but quits the program without defect
  if r.isOk:
    when T is not void:
      return r.value
  else:
    # let errVal = r.error() # using Time in packages is causing `$`R to have sideeffects
    let errVal = r.unsafeError
    if msg != "":
      errQuit msg.appendError(errVal)
    else:
      errQuit errVal

