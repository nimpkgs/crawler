import std/[strutils]
import hwylterm

proc errQuitWithCode*(code: int, args: varargs[string, `$`]) =
  writeLine stderr, $bb"[b red]ERROR[/]: ", args.join("")
  quit code

proc errQuit*(args: varargs[string, `$`]) =
  errQuitWithCode 1, args

