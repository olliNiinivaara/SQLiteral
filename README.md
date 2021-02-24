# SQLiteral
A high level SQLite API for Nim

Supports multi-threading, prepared statements, proper typing, 
zero-copy data paths, debugging, JSON, optimizing, backups, and more...

## Documentation
[1.3.0](http://htmlpreview.github.io/?https://github.com/olliNiinivaara/SQLiteral/blob/master/doc/sqliteral130.html)
[2.0.0](http://htmlpreview.github.io/?https://github.com/olliNiinivaara/SQLiteral/blob/master/doc/sqliteral200.html)


## Installation
`nimble install sqliteral`

## Change log

**1.3.0 (2021-02-19) current release**
* take backups concurrently
* database open supports multiple schemas
* partition states removed

**2.0.0 pre-release (2021-02-24) current master**
* thread-local isolated data structures make all interferences between threads impossible
* better support for experimental:view -based zero-copy strings
* JSON helper functions, JSON in documentation example
* breaking API change: New prepareStatements() proc must be used

## Example (version 2.0.0)

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
  db.setLogger(proc(db: SQLiteral, msg: string, code: int) = echo msg)

db.openDatabase("example.db", Schema)
db.prepareStatements(SqlStatements)
echo "count=",db.getTheInt(Select, 1) 
db.transaction: db.exec(Increment, 1)
for row in db.rows(SelectAll): echo row.getInt(CountColumn)
db.close
```
