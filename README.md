# SQLiteral
A high level SQLite API for Nim

Supports multi-threading, prepared statements, proper typing, 
zero-copy data paths, debugging, JSON, optimizing, backups, and more...

## Documentation

http://olliNiinivaara.github.io/SQLiteral/


## Installation

`nimble install sqliteral`

## 2.0.1 Release notes (2021-08-11)
* removed spurious debug echo
* better logging
* better example

## Example

```nim
import sqliteral
const Schema = """
  CREATE TABLE IF NOT EXISTS Example(count INTEGER NOT NULL);
  INSERT INTO Example(rowid, count) VALUES(1, 1)
   ON CONFLICT(rowid) DO UPDATE SET count=count+100
  """
const CountColumn = 0
type SqlStatements = enum
  Increment = "UPDATE Example SET count=count+1 WHERE rowid = ?"
  Select = "SELECT count FROM Example WHERE rowid = ?"
  SelectAll = "SELECT count FROM Example"
var db: SQLiteral

proc operate() =
  echo "count=",db.getTheInt(Select, 1)
  db.transaction: db.exec(Increment, 1)
  for row in db.rows(SelectAll): echo row.getInt(CountColumn)

when not defined(release):
  db.setLogger(proc(db: SQLiteral, msg: string, code: int) = echo msg)

db.openDatabase("example.db", Schema)
db.prepareStatements(SqlStatements)
operate()
db.close()
```
