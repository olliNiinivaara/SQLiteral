const SQLiteralVersion* = "1.3.0"

# (C) Olli Niinivaara, 2020
# MIT Licensed

## A high level SQLite API with support for multi-threading, prepared statements,
## proper typing, zero-copy string views, debugging executed statements,
## static binding to sqlite3.c of your choice, optimizing, backups, and more.
## 
## A Complete Example
## ==================
##
## .. code-block:: Nim
## 
##  import sqliteral
##  
##  const
##    Schema = "CREATE TABLE IF NOT EXISTS Example(data TEXT NOT NULL)"
##  
##  type SqlStatements = enum
##    Insert = "INSERT INTO Example (data) VALUES (?)"
##    Update = "UPDATE Example SET data = ? WHERE rowid = ?"
##    Select = "SELECT data FROM Example WHERE rowid = ?"
##    SelectAll = "SELECT rowid, data FROM Example"
##    Delete = "DELETE FROM Example WHERE rowid = ?"
##  
##  const
##    Rowid = 0
##    Data = 1
##  
##  var db: SQLiteral
##  var state: int
##  
##  
##  proc operate() =
##    {.gcsafe.}:
##      echo "startstate: ", state
##      
##      for i in 0 .. 9:
##        db.transaction:
##          let newrowid = db.insert(Insert, "dada")
##          let value = db.getTheString(Select, newrowid)
##          let updatedvalue = value & " " & $newrowid
##          db.exec(Update, updatedvalue, newrowid)
##          echo "+ ", updatedvalue
##      
##      for row in db.rows(SelectAll): echo row.getString(Data)
##      
##      db.transaction:
##        for row in db.rows(SelectAll):
##          let rowid = row.getInt(Rowid)
##          if rowid mod 3 == 0:
##            db.exec(Delete, rowid)
##            echo "- ", row.getString(Data)
##      
##      echo "endstate: ", state
##  
##  
##  when not defined(release):
##    proc logSql(db: SQLiteral, msg: string, code: int) = echo code," ",msg
##    db.setLogger(logSql)
##  
##  db.openDatabase("testdatabase", Schema, SqlStatements)
##  db.about()
##  db.setOnCommitCallback(proc (db: SQLiteral) = state.atomicInc)
##  var threads: array[5, Thread[void]]
##  for i in 0 .. threads.high: createThread(threads[i], operate)
##  joinThreads(threads)
##  db.optimize()
##  db.close()
##
## Compiling
## =========
## 
## sqlite3.c amalgamation must be on compiler search path, get yours from
## https://www.sqlite.org/download.html.
## 
## Compile command must define: `-d:staticSqlite`
## 
## An example: `nim c -r --experimental:views --threads:on -d:staticSqlite myprogram`
## 
## See also
## ========
## 
## | `sqlite <https://nim-lang.org/docs/db_sqlite.html>`_
## | `tiny_sqlite <https://gulpf.github.io/tiny_sqlite/tiny_sqlite.html>`_
##

{.passL: "-lpthread".}

import sqlite3
export PStmt, errmsg, reset, step, finalize, SQLITE_ROW
import Locks
from os import getFileSize
from strutils import strip, split, replace # Sic

const
  MaxStatements* {.intdefine.} = 100
    ## Compile time define pragma that limits amount of prepared statements
  

type
  SQLError* = object of CatchableError
    ## https://www.sqlite.org/rescode.html
    rescode*: int

  SQLiteral* = object
    sqlite*: PSqlite3
    dbname*: string
    inreadonlymode*: bool
    intransaction: bool
    walmode: bool 
    maxsize: int    
    transactionlock: Lock
    preparedstatements: array[MaxStatements, PStmt]
    laststatementindex: int
    loggerproc: proc(sqliteral: SQLiteral, statement: string, errorcode: int) {.gcsafe, raises: [].}
    oncommitproc: proc(sqliteral: SQLiteral) {.gcsafe, raises: [].}
    maxparamloggedlen: int
    Transaction: PStmt
    Commit: PStmt
    Rollback: PStmt

type
  DbValueKind = enum
    sqliteInteger,
    sqliteReal,
    sqliteText,
    sqliteBlob

when compiles(var x = toOpenArray("x", 0, 0)):
  type
    DbValue* = object
      ## | Represents a value in a SQLite database.
      ## | https://www.sqlite.org/datatype3.html
      ## | NULL values are not possible to avoid the billion-dollar mistake.
      case kind*: DbValueKind
      of sqliteInteger:
        intVal*: int64
      of sqliteReal:
        floatVal*: float64
      of sqliteText:
        textVal*: openArray[char]
      of sqliteBlob:
        blobVal*: seq[byte]
else:
  type
    DbValue* = object
      ## | Represents a value in a SQLite database.
      ## | https://www.sqlite.org/datatype3.html
      ## | NULL values are not possible to avoid the billion-dollar mistake.
      case kind*: DbValueKind
      of sqliteInteger:
        intVal*: int64
      of sqliteReal:
        floatVal*: float64
      of sqliteText:
        deprecatedtextVal*: Text
          ## use --experimental:views compile flag to use openArray[char] instead.
          ## (unfortunately nimdoc does not support the feature.)
      of sqliteBlob:
        blobVal*: seq[byte]

    # Text ----------------------------------------------------

    Text* = tuple[data: ptr UncheckedArray[char], len: int32]
      ## Compile with --experimental:views to get proper language-supported zero-copy
      ## views to slices of existing strings.
      ## Current hack is deprecated and will be removed when views become official...
      ## 
      ## To avoid copying strings, SQLiteral offers Text as a zero-copy view to a slice of existing string
      ## 
      ## **Example:**
      ##
      ## .. code-block:: Nim
      ##
      ##    var buffer = """{"sentence": "Call me Ishmael"}"""
      ##    let value = asText(buffer, buffer.find(" \"")+2, buffer.find("\"}")-1)
      ##    assert value.equals("Call me Ishmael")
      ##    db.exec(Update, value, rowid)

  var emptytext = "X"
  var emptystart = cast[ptr UncheckedArray[char]](addr emptytext[0])

  proc asText*(fromstring: string, start: int, last: int): Text {.deprecated.} =
    ## Creates a zero-copy view to a substring of existing string
    doAssert(last < fromstring.len)
    doAssert(last < int32.high)
    (cast[ptr UncheckedArray[char]](fromstring[start].unsafeAddr), (last - start + 1).int32)

  proc equals*(text: Text, str: string): bool {.inline, deprecated.} =
    if text.len != str.len: return false
    for i in 0 ..< text.len:
      if text.data[i] != str[i]: return false
    return true

  proc `$`*(text: Text): string =
    for i in 0 ..< text.len: result.add(text.data[i])

  proc len*(text: Text): int {.inline, deprecated.} = text.len

  proc substr*(text: Text, start: int, last: int): string {.deprecated.} =
    for i in start ..< last: result.add(text.data[i])

  # ----------------------------------------------------------


template checkRc*(db: SQLiteral, resultcode: int) =
  ## Raises SQLError if resultcode notin [SQLITE_OK, SQLITE_ROW, SQLITE_DONE]
  ## https://www.sqlite.org/rescode.html
  if resultcode notin [SQLITE_OK, SQLITE_ROW, SQLITE_DONE]:
    let errormsg = $db.sqlite.errmsg()
    if(unlikely) db.loggerproc != nil: db.loggerproc(db, errormsg, resultcode)
    raise (ref SQLError)(msg: db.dbname & " " & errormsg, rescode: resultcode)


proc toDb*[T: Ordinal](val: T): DbValue {.inline.} = DbValue(kind: sqliteInteger, intVal: val.int64)

proc toDb*[T: SomeFloat](val: T): DbValue {.inline.} = DbValue(kind: sqliteReal, floatVal: val.float64)

when compiles(var x = toOpenArray("x", 0, 0)):
  proc toDb*[T: string](val: T): DbValue {.inline.} =
    DbValue(kind: sqliteText, textVal: toOpenArray(val, 0, val.high))
else:
  proc toDb*[T: string](val: T): DbValue {.inline.} =
    if val.len == 0:
      DbValue(kind: sqliteText, deprecatedtextVal: (emptystart , 0.int32))
    else:
      DbValue(kind: sqliteText, deprecatedtextVal: (cast[ptr UncheckedArray[char]](val[0].unsafeAddr) , val.len.int32))

  proc toDb*[T: Text](val: T): DbValue {.inline.} =
    if val[1] < 0 or val[1] > high(int32):  raise (ref SQLError)(msg: "Text weird len: " & $val[1])
    DbValue(kind: sqliteText, textVal: val)

proc toDb*[T: seq[byte]](val: T): DbValue {.inline.} = DbValue(kind: sqliteBlob, blobVal: val) # TODO: test
  
proc toDb*[T: DbValue](val: T): DbValue {.inline.} = val

when compiles(var x = toOpenArray("x", "0", 0)):
  proc `$`*[T: DbValue](val: T): string {.inline.} = 
    case val.kind
    of sqliteInteger: $val.intval
    of sqliteReal: $val.floatVal
    of sqliteText: $val.textVal
    of sqliteBlob: cast[string](val.blobVal)
else:
  proc `$`*[T: DbValue](val: T): string {.inline.} = 
    case val.kind
    of sqliteInteger: $val.intval
    of sqliteReal: $val.floatVal
    of sqliteText: $val.deprecatedtextVal
    of sqliteBlob: cast[string](val.blobVal)


when compiles(var x = toOpenArray("x", "0", 0)):
  proc bindParams*(sql: PStmt, params: varargs[DbValue]): int {.inline.} =
    var idx = 1.int32
    for value in params:
      result =
        case value.kind
        of sqliteInteger: bind_int64(sql, idx, value.intval)
        of sqliteReal: bind_double(sql, idx, value.floatVal)
        of sqliteText: bind_text(sql, idx, cstring(unsafeAddr value.textVal[0]), value.textVal.len().int32, SQLITE_STATIC)
        of sqliteBlob: bind_blob(sql, idx.int32, cast[string](value.blobVal).cstring,
         value.blobVal.len.int32 , SQLITE_STATIC) # TODO: test
      if result != SQLITE_OK: return
      idx.inc
else:
  proc bindParams*(sql: PStmt, params: varargs[DbValue]): int {.inline.} =
    var idx = 1.int32
    for value in params:
      result =
        case value.kind
        of sqliteInteger: bind_int64(sql, idx, value.intval)
        of sqliteReal: bind_double(sql, idx, value.floatVal)
        of sqliteText: bind_text(sql, idx, value.deprecatedtextVal[0], value.deprecatedtextVal[1].int32, SQLITE_STATIC)
        of sqliteBlob: bind_blob(sql, idx.int32, cast[string](value.blobVal).cstring,
         value.blobVal.len.int32 , SQLITE_STATIC) # TODO: test
      if result != SQLITE_OK: return
      idx.inc


template log() =
  var logstring = $statement
  var replacement = 0
  while replacement < params.len:
    let position = logstring.find('?')
    assert(position != -1, "too many params (" & $params.len & ") for: " & $statement)    
    let param =
      if db.maxparamloggedlen < 1: $params[replacement]
      else: ($params[replacement]).substr(0, db.maxparamloggedlen - 1)
    logstring = logstring[0 .. position-1] & param & logstring.substr(position+1)
    replacement += 1
  db.loggerproc(db, logstring, 0)


proc doLog*(db: SQLiteral, statement: string, params: varargs[DbValue, toDb]) {.inline.} =
  if statement == "Pstmt rows" or statement == "exec Pstmt": db.loggerproc(db, statement & " " & $params, 0)
  else: log()
 

proc getInt*(prepared: PStmt, col: int32 = 0): int64 {.inline.} =
  ## Returns value of INTEGER -type column at given column index
  return column_int64(prepared, col)


proc getString*(prepared: PStmt, col: int32 = 0): string {.inline.} =
  ## Returns value of TEXT -type column at given column index as string
  return $column_text(prepared, col)


proc getCString*(prepared: PStmt, col: int32 = 0): cstring {.inline.} =
  ## | Returns value of TEXT -type column at given column index as cstring.
  ## | The result is not available after cursor movement or statement reset.
  return column_text(prepared, col)


proc getFloat*(prepared: PStmt, col: int32 = 0): float64 {.inline.} =
  ## Returns value of REAL -type column at given column index
  return column_double(prepared, col)


proc getSeq*(prepared: PStmt, col: int32 = 0): seq[byte] {.inline.} =
  ## Returns value of BLOB -type column at given column index
  let blob = column_blob(prepared, col)
  let bytes = column_bytes(prepared, col)
  result = newSeq[byte](bytes)
  if bytes != 0: copyMem(addr(result[0]), blob, bytes)


iterator rows*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb]): PStmt =
  ## Iterates over the query results
  if(unlikely) db.loggerproc != nil: log()
  let s = db.preparedstatements[ord(statement)]
  checkRc(db, bindParams(s, params))
  defer: discard sqlite3.reset(s)
  while step(s) == SQLITE_ROW: yield s


iterator rows*(db: SQLiteral, pstatement: Pstmt, params: varargs[DbValue, toDb]): PStmt =
  ## Iterates over the query results
  if(unlikely) db.loggerproc != nil: db.doLog("Pstmt rows", params)
  checkRc(db, bindParams(pstatement, params))
  defer: discard sqlite3.reset(pstatement)
  while step(pstatement) == SQLITE_ROW: yield pstatement


proc prepareSql*(db: SQLiteral, sql: cstring): PStmt {.inline.} =
  ## Prepares a cstring into an executable statement
  # nim 1.2 regression workaround, see https://github.com/nim-lang/Nim/issues/13859
  let len = sql.len.float32
  checkRc(db, prepare_v2(db.sqlite, sql, len.cint, result, nil))
  return result


proc getTheInt*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb]): int64 {.inline.} =
  ## | Executes query and returns value of INTEGER -type column at column index 0 of first result row.
  ## | If query does not return any rows, returns -2147483647 (low(int32) + 1).
  ## | Automatically resets the statement.
  if(unlikely) db.loggerproc != nil: log()
  let s = db.preparedstatements[ord(statement)]
  checkRc(db, bindParams(s, params))
  defer: discard sqlite3.reset(s)
  if step(s) == SQLITE_ROW: s.getInt(0) else: -2147483647


proc getTheInt*(db: SQLiteral, s: string): int64 {.inline.} =
  ## | Dynamically prepares, executes and finalizes given query and returns value of INTEGER -type
  ## column at column index 0 of first result row.
  ## | If query does not return any rows, returns -2147483647 (low(int32) + 1).
  if(unlikely) db.loggerproc != nil: db.loggerproc(db, s, 0)
  let query = db.prepareSql(s)
  try:
    let rc = step(query)
    checkRc(db, rc)
    result = if rc == SQLITE_ROW: query.getInt(0) else: -2147483647
  finally:
    discard finalize(query)


proc getTheString*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb]): string {.inline.} =
  ## | Executes query and returns value of TEXT -type column at column index 0 of first result row.
  ## | If query does not return any rows, returns empty string.
  ## | Automatically resets the statement.
  if(unlikely) db.loggerproc != nil: log()
  let s = db.preparedstatements[ord(statement)]
  checkRc(db, bindParams(s, params))
  defer: discard sqlite3.reset(s)
  if step(s) == SQLITE_ROW: s.getString(0) else: ""


proc getTheString*(db: SQLiteral, s: string): string {.inline.} =
  ## | Dynamically prepares, executes and finalizes given query and returns value of TEXT -type
  ## column at column index 0 of first result row.
  ## | If query does not return any rows, returns empty string.
  if(unlikely) db.loggerproc != nil: db.loggerproc(db, s, 0)
  let query = db.prepareSql(s)
  try:
    let rc = step(query)
    checkRc(db, rc)
    result = if rc == SQLITE_ROW: query.getString(0) else: ""
  finally:
    discard finalize(query)


proc getLastInsertRowid*(db: SQLiteral): int64 {.inline.} =
  ## https://www.sqlite.org/c3ref/last_insert_rowid.html
  return db.sqlite.last_insert_rowid()


proc rowExists*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb]): bool {.inline.} =
  ## Returns true if query returns any rows
  if(unlikely) db.loggerproc != nil: log()
  let s = db.preparedstatements[ord(statement)]
  checkRc(db, bindParams(s, params))
  defer: discard sqlite3.reset(s)
  return step(s) == SQLITE_ROW


proc rowExists*(db: SQLiteral, sql: string): bool {.inline.} =
  ## Returns true if query returns any rows
  if(unlikely) db.loggerproc != nil: db.loggerproc(db, sql, 0)
  let preparedstatement = db.prepareSql(sql.cstring)
  defer: discard finalize(preparedstatement)
  return step(preparedstatement) == SQLITE_ROW


template withRow*(db: SQLiteral, sql: string, row, body: untyped) =
  ## | Dynamically prepares and finalizes an sql query.
  ## | Name for the resulting prepared statement is given with row parameter.  
  ## | The code block will be executed only if query returns a row.
  if(unlikely) db.loggerproc != nil: db.loggerproc(db, sql, 0)
  let preparedstatement = db.prepareSql(sql.cstring)
  try:
    if step(preparedstatement) == SQLITE_ROW:
      var row {.inject.} = preparedstatement
      body
  finally:
    discard finalize(preparedstatement)


template withRowOr*(db: SQLiteral, sql: string, row, body1, body2: untyped) =
  ## | Dynamically prepares and finalizes an sql query.
  ## | Name for the resulting prepared statement is given with row parameter.  
  ## | First block will be executed if query returns a row, otherwise the second block.
  ## **Example:**
  ## 
  ## .. code-block:: Nim
  ## 
  ##  db.withRowOr("SELECT (1) FROM sqlite_master", rowname):
  ##    echo "database has some tables because first column = ", rowname.getInt(0)
  ##  do:
  ##    echo "we have a fresh database"
  ## 
  if(unlikely) db.loggerproc != nil: db.loggerproc(db, sql, 0)
  let preparedstatement = db.prepareSql(sql.cstring)
  try:
    if step(preparedstatement) == SQLITE_ROW:
      var row {.inject.} = preparedstatement
      body1
    else: body2
  finally:
    discard finalize(preparedstatement)


template withRow*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb], row, body: untyped) {.dirty.} =
  ## | Executes given prepared statement.
  ## | Name for the prepared statement is given with row parameter.
  ## | The code block will be executed only if query returns a row.
  if(unlikely) db.loggerproc != nil: db.doLog($statement, params)
  let s = db.preparedstatements[ord(statement)]
  defer: discard reset(s)
  checkRc(db, bindParams(s, params))
  if step(s) == SQLITE_ROW:
    var row {.inject.} = s
    body
    

template withRowOr*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb], row, body1, body2: untyped) =
  ## | Executes given prepared statement.
  ## | Name for the prepared statement is given with row parameter.  
  ## | First block will be executed if query returns a row, otherwise the second block.
  if(unlikely) db.loggerproc != nil: db.doLog($statement, params)
  let s = db.preparedstatements[ord(statement)]
  checkRc(db, bindParams(s, params))
  try:
    if step(s) == SQLITE_ROW:
      var row {.inject.} = s
      body1
    else: body2
  finally:
    discard reset(s)


proc exec*(db: SQLiteral, pstatement: Pstmt, params: varargs[DbValue, toDb]) {.inline.} =
  ## Executes given prepared statement
  if(unlikely) db.loggerproc != nil: db.doLog("exec Pstmt", params)
  defer: discard sqlite3.reset(pstatement)
  checkRc(db, bindParams(pstatement, params))
  checkRc(db, step(pstatement))


proc exec*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb]) {.inline.} =
  ## Executes given statement
  if(unlikely) db.loggerproc != nil: log()
  let s = db.preparedstatements[ord(statement)]
  defer: discard sqlite3.reset(s)
  checkRc(db, bindParams(s, params))
  checkRc(db, step(s))


proc exes*(db: SQLiteral, sql: string) =
  ## | Prepares, executes and finalizes given semicolon-separated sql statements.
  if(unlikely) db.loggerproc != nil: db.loggerproc(db, sql, -1)
  var errormsg: cstring
  let rescode = sqlite3.exec(db.sqlite, sql.cstring, nil, nil, errormsg)
  if rescode != 0:
    var error: string
    if errormsg != nil:
      error = $errormsg
      free(errormsg)
    if(unlikely) db.loggerproc != nil: db.loggerproc(db, error, rescode)
    raise (ref SQLError)(msg: db.dbname & " " & $rescode & " " & error)


proc insert*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb]): int64 {.inline.} =
  ## | Executes given statement and, if succesful, returns db.getLastinsertRowid().
  ## | If not succesful, returns -2147483647 (low(int32) + 1).
  if(unlikely) db.loggerproc != nil: log()
  let s = db.preparedstatements[ord(statement)]
  defer: discard sqlite3.reset(s)
  checkRc(db, bindParams(s, params))
  result =
    if step(s) == SQLITE_DONE: db.getLastinsertRowid()
    else: -2147483647


proc update*(db: SQLiteral, sql: string, column: string, newvalue: DbValue, where: DbValue) =
  ## | Dynamically constructs, prepares, executes and finalizes given update query.
  ## | Update must target one column and WHERE -clause must contain one value.
  ## | For security and performance reasons, this proc should be used with caution.
  if column.find(' ') != -1: raise (ref Exception)(msg: "Column must not contain spaces: " & column)
  let update = sql.replace("Column", column).cstring
  var pstmt: PStmt
  if(unlikely) db.loggerproc != nil: db.loggerproc(db, $update & " (" & $newvalue & ", " & $where & ")", 0)
  checkRc(db, prepare_v2(db.sqlite, update, update.len.cint, pstmt, nil))
  try:
    db.exec(pstmt, newvalue, where)
  finally:
    discard pstmt.finalize()


proc columnExists*(db: SQLiteral, table: string, column: string): bool =
  ## Returns true if given column exists in given table
  result = false
  if table.find(' ') != -1: raise (ref Exception)(msg: "Table must not contain spaces: " & table)
  if column.find(' ') != -1: raise (ref Exception)(msg: "Column must not contain spaces: " & column)
  let sql = ("SELECT count(*) FROM pragma_table_info('" & table & "') WHERE name = '" & column & "'").cstring
  if(unlikely) db.loggerproc != nil: db.loggerproc(db, $sql, 0)
  let pstmt = db.prepareSql(sql)
  try:
    if step(pstmt) == SQLITE_ROW: result = pstmt.getInt(0) == 1
  finally:
    discard sqlite3.reset(pstmt)
    discard pstmt.finalize()
  

template transaction*(db: var SQLiteral, statepartition: uint32, body: untyped) =
  ## statepartition handling is being deprecated; create your own state handler with setOnCommitCallback instead 
  if not db.inreadonlymode:
    assert(statepartition < 100, "statepartition out of bounds")
    acquire(db.transactionlock)
    db.exec(db.Transaction)
    db.intransaction = true
    if(unlikely) db.loggerproc != nil: db.loggerproc(db, "--- BEGIN TRANSACTION", 0)
    try: body
    except Exception as ex:
      db.exec(db.Rollback)
      if(unlikely) db.loggerproc != nil: db.loggerproc(db, "--- ROLLBACK", 0)
      db.intransaction = false
      raise ex
    finally:
      if db.intransaction:
        db.exec(db.Commit)
        if db.oncommitproc != nil: db.oncommitproc(db)
        db.intransaction = false
        if(unlikely) db.loggerproc != nil: db.loggerproc(db, "--- COMMIT", 0)
      release(db.transactionlock)


template transaction*(db: SQLiteral, body: untyped) =
  ## | Every write to database must happen inside some transaction.
  ## | Groups of reads must be wrapped in same transaction if mutual consistency required.
  ## | In WAL mode (the default), independent reads must NOT be wrapped in transaction to allow parallel processing.
  transaction(db, 0, body)


template transactionsDisabled*(db: var SQLiteral, body: untyped) =
  ## Executes body with all transactions disabled.
  acquire(db.transactionlock)
  if(unlikely) db.loggerproc != nil: db.loggerproc(db, "--- TRANSACTIONS DISABLED", 0)
  try:
    body
  finally:
    if(unlikely) db.loggerproc != nil: db.loggerproc(db, "--- TRANSACTIONS ENABLED", 0)
    release(db.transactionlock)


proc isIntransaction*(db: SQLiteral): bool {.inline.} =
  return db.intransaction


proc createStatement(db: var SQLiteral, statement: enum) =
  let index = ord(statement)
  assert(index < MaxStatements, "Statement index " & $index & " out of MaxStatements: " & $MaxStatements)
  assert(db.preparedstatements[index] == nil, "statement index " & $index & " is already in use")
  if(unlikely) db.loggerproc != nil: db.loggerproc(db, $statement, -1)
  db.preparedstatements[index] = prepareSql(db, ($statement).cstring)
  if index > db.laststatementindex: db.laststatementindex = index


proc setLogger*(db: var SQLiteral, logger: proc(sqliteral: SQLiteral, statement: string, code: int)
 {.gcsafe, raises: [].}, paramtruncat = 50) =
  ## Set callback procedure to gather all executed statements with their parameters.
  ## 
  ## If code > 0, log concerns sqlite error with error code in question.
  ## 
  ## If code == -1, log may be of minor interest (originating from `exes` or statement preparation).
  ##
  ## Paramtruncat parameter limits the maximum log length of parameters so that long inputs won't
  ## clutter logs. Value < 1 disables truncation.
  ##
  ## You can use the same logger for multiple sqliterals, the caller is also given as parameter.
  db.maxparamloggedlen = paramtruncat
  db.loggerproc = logger


proc setOnCommitCallback*(db: var SQLiteral, oncommit: proc(sqliteral: SQLiteral) {.gcsafe, raises: [].}) =
  ## Set callback procedure that is triggered inside transaction proc, when commit to database has been executed.
  db.oncommitproc = oncommit


proc openDatabase*(db: var SQLiteral, dbname: string, schemas: openArray[string],
 Statements: typedesc[enum], maxKbSize = 0, wal = true) =
  ## Opens an exclusive connection, boots up the database, executes given schemas and prepares given statements.
  ## 
  ## If dbname is not a path, current working directory will be used.
  ## 
  ## | If wal = true, database is opened in WAL mode with NORMAL synchronous setting.
  ## | If wal = false, database is opened in PERSIST mode with FULL synchronous setting.
  ## | https://www.sqlite.org/wal.html
  ## | https://www.sqlite.org/pragma.html#pragma_synchronous
  ## 
  ## If maxKbSize == 0, database size is limited only by OS or hardware with possibly severe consequences.
  ##
  doAssert dbname != ""
  initLock(db.transactionlock)
  db.dbname = dbname
  db.laststatementindex = -1
  db.checkRc(open(dbname, db.sqlite))
 
  db.exes("PRAGMA encoding = 'UTF-8'")
  db.exes("PRAGMA foreign_keys = ON")
  db.exes("PRAGMA locking_mode = EXCLUSIVE")
  db.walmode = wal
  if wal: db.exes("PRAGMA journal_mode = WAL")
  else:
    db.exes("PRAGMA journal_mode = PERSIST")
    db.exes("PRAGMA synchronous = FULL")
  if maxKbSize > 0:
    db.maxsize = maxKbSize
    let pagesize = db.getTheInt("PRAGMA page_size")
    db.exes("PRAGMA max_page_count = " & $(maxKbSize * 1024 div pagesize))
  for schema in schemas: db.exes(schema)
  db.Transaction = db.prepareSql("BEGIN IMMEDIATE".cstring)
  db.Commit = db.prepareSql("COMMIT".cstring)
  db.Rollback = db.prepareSql("ROLLBACK".cstring)
  for v in low(Statements) .. high(Statements): db.createStatement(v) #ord(v), ($v).cstring)
  if db.loggerproc != nil: db.loggerproc(db, "opened", -1)
  elif defined(fulldebug): echo "notice: fulldebug defined but logger not set for ", db.dbname
  

proc openDatabase*(db: var SQLiteral, dbname: string, schema: string,
 Statements: typedesc[enum], maxKbSize = 0, wal = true) {.inline.} =
  ## Open database with a single schema.
  openDatabase(db, dbname, [schema], Statements, maxKbSize, wal)
  

proc setReadonly*(db: var SQLiteral, readonly: bool) =
  ## When in readonly mode:
  ## 
  ## 1) All transactions will be silently discarded
  ## 
  ## 2) Journal mode is changed to PERSIST in order to be able to change locking mode
  ## 
  ## 3) Locking mode is changed from EXCLUSIVE to NORMAL, allowing other connections access the database
  ## 
  ## Setting readonly fails with exception "cannot change into wal mode from within a transaction"
  ## when a statement is being executed, for example a result of a select is being iterated.
  ## 
  ## ``inreadonlymode`` property tells current mode.
  if readonly == db.inreadonlymode: return
  db.transactionsDisabled:
    if readonly:
      db.inreadonlymode = readonly
      db.exes("PRAGMA journal_mode = PERSIST")
      db.exes("PRAGMA locking_mode = NORMAL")
      db.exes("SELECT (1) FROM sqlite_master") #  dummy access to release file lock
    else:
      if db.walmode: db.exes("PRAGMA journal_mode = WAL")
      db.exes("PRAGMA locking_mode = EXCLUSIVE") # next write will keep the file lock
      db.inreadonlymode = readonly
    if(unlikely) db.loggerproc != nil: db.loggerproc(db, "--- READONLY MODE: " & $readonly , 0)
    

proc optimize*(db: var SQLiteral, pagesize = -1, walautocheckpoint = -1) =
  ## Vacuums and optimizes the database.
  ## 
  ## This proc should be run just before closing, when no other thread accesses the database.
  ## 
  ## | In addition, database read/write performance ratio may be adjusted with parameters:
  ## | https://sqlite.org/pragma.html#pragma_page_size
  ## | https://www.sqlite.org/pragma.html#pragma_wal_checkpoint
  acquire(db.transactionlock)
  try:   
    db.exes("PRAGMA optimize")
    if walautocheckpoint > -1: db.exes("PRAGMA wal_autocheckpoint = " & $walautocheckpoint)
    if pagesize > -1:
      db.exes("PRAGMA journal_mode = PERSIST")
      db.exes("PRAGMA page_size = " & $pagesize)  
    db.exes("VACUUM")      
    if pagesize > -1 and db.walmode: db.exes("PRAGMA journal_mode = WAL")
  except:
    if db.loggerproc != nil: db.loggerproc(db, getCurrentExceptionMsg(), -1)
    else: echo "Could not optimize ", db.dbname, ": ", getCurrentExceptionMsg()
  finally:
    release(db.transactionlock)


proc initBackup*(db: SQLiteral, backupfilename: string):
 tuple[backupdb: Psqlite3, backuphandle: PSqlite3_Backup] =
  ## Initializes backup processing, returning variables to use with `stepBackup` proc.
  ## 
  ## Note that `close` will fail with SQLITE_BUSY if there's an unfinished backup process going on.
  db.checkRc(open(backupfilename, result.backupdb))
  result.backuphandle = backup_init(result.backupdb, "main".cstring, db.sqlite, "main".cstring)
  if result.backuphandle == nil: db.checkRc(SQLITE_NULL)
  if db.loggerproc != nil: db.loggerproc(db, "backup to " & backupfilename, 0)


proc stepBackup*(db: SQLiteral, backupdb: Psqlite3, backuphandle: PSqlite3_Backup, pagesperportion = 5.int32): int =
  ## Backs up a portion of the database pages (default: 5) to a destination initialized with `initBackup`.
  ##
  ## Returns percentage of progress; 100% means that backup has been finished.
  ## 
  ## The idea `(check example 2)<https://sqlite.org/backup.html>`_ is to put the thread to sleep
  ## between portions so that other operations can proceed concurrently.
  ##
  ## **Example:**
  ## 
  ## .. code-block:: Nim
  ##  
  ##  from os import sleep 
  ##  let (backupdb , backuphandle) = db.initBackup("./backup.db")
  ##  var progress: int
  ##  while progress < 100:
  ##    sleep(250)
  ##    progress = db.stepBackup(backupdb, backuphandle)
  ## 
  if unlikely(backupdb == nil or backuphandle == nil): db.checkRc(SQLITE_NULL)
  var rc = backup_step(backuphandle, pagesperportion)
  if rc == SQLITE_DONE:
    db.checkRc(backup_finish(backuphandle))
    db.checkRc(backupdb.close())
    if db.loggerproc != nil: db.loggerproc(db, "backup ok", 0)
    return 100
  if rc notin [SQLITE_OK, SQLITE_BUSY, SQLITE_LOCKED]:
    if db.loggerproc != nil: db.loggerproc(db, "backup failed", rc)
    discard backup_finish(backuphandle)
    discard backupdb.close()
    db.checkRc(rc)
  return 100 * (backuphandle.backup_pagecount - backuphandle.backup_remaining) div backuphandle.backup_pagecount


proc about*(db: SQLiteral) =
  ## Echoes some info about the database.
  echo ""
  echo db.dbname & ": "
  echo "SQLiteral=", SQLiteralVersion
  echo "SQLite=", libversion()
  echo "Userversion=", db.getTheString("PRAGMA user_version")
  let Get_options = db.prepareSql("PRAGMA compile_options")
  for row in db.rows(Get_options): echo row.getString()
  discard finalize(Get_options)
  echo "Pagesize=", $db.getTheInt("PRAGMA page_size")
  echo "WALautocheckpoint=", $db.getTheInt("PRAGMA wal_autocheckpoint")
  echo "Preparedstatements=", $(db.laststatementindex + 1)
  let filesize = getFileSize(db.dbname)
  echo "Filesize=", filesize
  if db.maxsize > 0:
    echo "Maxsize=", db.maxsize * 1024
    echo "Sizeused=", (filesize div ((db.maxsize.float * 10.24).int)), "%"
  echo ""


proc finalizeStatements(db: var SQLiteral) =
  if db.Transaction == nil: return
  discard db.Transaction.finalize()
  db.Transaction = nil
  discard db.Commit.finalize()
  discard db.Rollback.finalize()
  for i in 0 .. db.laststatementindex: discard db.preparedstatements[i].finalize()


proc close*(db: var SQLiteral) =
  ## Closes the database.
  if db.laststatementindex == -1: return
  var rc = 0
  acquire(db.transactionlock)
  try:
    finalizeStatements(db)
    rc = close(db.sqlite)
    if rc == SQLITE_OK:
      if db.loggerproc != nil: db.loggerproc(db, "closed", 0)
    else: db.checkRc(rc)
  except:
    if db.loggerproc == nil: echo "Could not close ", db.dbname, ": ", getCurrentExceptionMsg()
    elif rc == 0: db.loggerproc(db, getCurrentExceptionMsg(), 1)
  finally:
    db.laststatementindex = -1
    release(db.transactionlock)
    deinitLock(db.transactionlock)