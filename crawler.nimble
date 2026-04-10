# Package

version       = "2025.1004"
author        = "Daylin Morgan"
description   = "nimpkgs crawler"
license       = "MIT"
srcDir        = "src"
bin           = @["crawler"]


# Dependencies

requires "nim >= 2.0.0"
requires "jsony"
requires "hwylterm#2772aa27"
requires "chronos"
requires "https://github.com/daylinmorgan/resultz"
