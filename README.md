# SQLiteral
A high level SQLite API for Nim

Supports multi-threading, prepared statements, proper typing, zero-copy string views,
debugging executed statements, static binding to sqlite3.c of your choice, optimizing, backups, and more...

## Documentation
http://htmlpreview.github.io/?https://github.com/olliNiinivaara/SQLiteral/blob/master/doc/sqliteral.html

## Installation
`nimble install sqliteral`

## Change log

**1.3.0 (2021-02-19)**
* take backup concurrently
* database open supports multiple schemas
* partition states removed

## Roadmap

**1.4.0** https://www.sqlite.org/json1.html

**2.0.0** When views become officially supported in nim, remove Text

## Example

```nim
import sqliteral
const Schema = """
  CREATE TABLE IF NOT EXISTS Example(count INTEGER NOT NULL);
  INSERT INTO Example(rowid, count) VALUES(1, 1) ON CONFLICT(rowid) DO UPDATE SET count=count+100
  """
const CountColumn = 0
type SqlStatements = enum
  Increment = "UPDATE Example SET count=count+1 WHERE rowid = ?"
  Select = "SELECT count FROM Example WHERE rowid = ?"
  SelectAll = "SELECT count FROM Example"
var db: SQLiteral

when not defined(release):
  db.setLogger(proc(db: SQLiteral, msg: string, code: int) = echo code," ",msg)

db.openDatabase("example.db", Schema, SqlStatements)
echo "count=",db.getTheInt(Select, 1) 
db.transaction: db.exec(Increment, 1)
for row in db.rows(SelectAll): echo row.getInt(CountColumn)
db.close
```
