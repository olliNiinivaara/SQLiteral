# SQLiteral
A high level SQLite API for Nim

Supports multi-threading, prepared statements, proper typing, 
zero-copy data paths, debugging, JSON, optimizing, backups, and more...

## Documentation

http://olliNiinivaara.github.io/SQLiteral/


## Installation

`atlas use sqliteral`

## 4.0.0 Release notes (2023-08-19)
* Compatibility with Nim 2
* Single-threaded mode is not supported anymore (breaking change)
* Avoid crashing from trying to get filesize of in-memory database in about
* Unlimited amount of threads supported
* New finalizeStatements proc (semi-breaking change)
* New interrupt proc
* Various minor performance and other fixes

## Example

```nim
import sqliteral
const Schema = "CREATE TABLE IF NOT EXISTS Example(string TEXT NOT NULL)"
type SqlStatements = enum
  Upsert = """INSERT INTO Example(rowid, string) VALUES(1, ?)
   ON CONFLICT(rowid) DO UPDATE SET string = ?"""
  SelectAll = "SELECT string FROM Example"
var db: SQLiteral

proc operate(i: string) =
  let view: DbValue = i.toDb(3, 7) # zero-copy view into string
  db.transaction: db.exec(Upsert, view, view)
  for row in db.rows(SelectAll): echo row.getCString(0)

db.openDatabase("example.db", Schema)
db.prepareStatements(SqlStatements)
var input = "012INPUT89"
operate(input)
db.close()
```
