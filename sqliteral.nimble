# Package

version       = "1.0.0"
author        = "Olli"
description   = "A high level SQLite API for Nim"
license       = "MIT"
srcDir        = "src"



# Dependencies

requires "nim >= 1.2.0"
foreignDep "sqlite3.c"
