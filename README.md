# SQLiteral
A high level SQLite API for Nim

Supports multi-threading, prepared statements, proper typing, 
zero-copy data paths, debugging, optimizing, backups, and more...

## Documentation

http://olliNiinivaara.github.io/SQLiteral/

## 5.0.1 Release notes (2025-02-13)
* `withRow` template fix by removing a superfluous `dirty` pragma

## 5.0.0 Release notes (2024-12-22)
 * statements from more than one enum list can be used
 * a statement is prepared automatically on first use
 * all used statements are finalized automatically on close
 * only the Nim default memory managers (ARC and ORC family) are supported
 * errors that are not sqlite errors are logged with error code 10000
 * failing to close raises an SQLError
 * json_extract, json_patch, json_valid, and json_tree procs removed as too high level (esp. now that multiple statement lists are supported)

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
var input = "012INPUT89"
operate(input)
db.close()
```
