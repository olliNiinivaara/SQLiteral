# SQLiteral
A high level SQLite API for Nim

Supports multi-threading, prepared statements, proper typing, 
zero-copy data paths, debugging, JSON, optimizing, backups, and more...

## Documentation

http://olliNiinivaara.github.io/SQLiteral/


## Installation

`nimble install sqliteral`

## 2.0.0 Release notes (2021-03-17)
* breaking API change: New prepareStatements() proc must be used
* new thread-isolating data structures guarantee interference-free db operations
* better support for experimental:views -based zero-copy strings
* JSON helper functions, JSON in documentation example
* Selected errors during schema migrations can ignored
* backup processes can be canceled
* getStatus proc for https://www.sqlite.org/c3ref/c_dbstatus_options.html
* getAsStrings -proc for getting all result rows as a sequence of strings
* logger also checks that statements receive enough parameters

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

when not defined(release):
  db.setLogger(proc(db: SQLiteral, msg: string, code: int) = echo msg)

db.openDatabase("example.db", Schema)
db.prepareStatements(SqlStatements)
echo "count=",db.getTheInt(Select, 1) 
db.transaction: db.exec(Increment, 1)
for row in db.rows(SelectAll): echo row.getInt(CountColumn)
db.close
```
