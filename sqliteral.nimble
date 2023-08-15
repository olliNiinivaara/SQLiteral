# Package

version       = "3.0.1"
author        = "Olli"
description   = "A high level SQLite API for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 1.6"
when NimMajor == 2:
  requires "db_connector"
