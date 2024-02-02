import std/[

  strutils, terminal]

type
  ProgressBar* = object
    total*, current*: int
    progress*: float
    message*: string

proc newProgressBar*(length: int): ProgressBar =
  result.total = length

proc status*(pb: var ProgressBar, msg: string) =
  pb.message = msg

proc inc*(pb: var ProgressBar) =
  inc pb.current
  pb.progress = pb.current / pb.total

proc trim(s: string, length: int): string =
  if s.len > length: s[0..<length] & "..."
  else: s

proc `%`(pb: ProgressBar):string = $(int pb.progress * 100) & "%"

proc show*(pb: ProgressBar) =
  let
    halfScreen = int(terminalWidth() / 2)
    color =
      if pb.progress > 0.8:
        fgGreen
      elif pb.progress > 0.4:
        fgYellow
      else:
        fgRed

  stdout.styledWriteLine(
    "[",
    color,
    (
      '='.repeat(int(pb.progress * float(halfScreen - 2))) & ">"
    ).alignLeft(halfScreen-2),
    fgDefault,
    "]",
    color,
    " ",
    % pb,
    " ",
    fgDefault,
    pb.message.trim(halfScreen-6),
  )
  cursorUp 1
  eraseLine()

proc echo*(pb: ProgressBar, msg: string) =
  echo msg
  pb.show()
