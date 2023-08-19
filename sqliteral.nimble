# Package

version       = "4.0.0"
author        = "Olli"
description   = "A high level SQLite API for Nim"
license       = "MIT"

# Dependencies

requires "nim >= 1.6"
when NimMajor == 2:
  requires "db_connector"
