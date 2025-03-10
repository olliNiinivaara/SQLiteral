const SQLiteralVersion* = "5.0.1"
static: doAssert(compileOption("threads"))
when not defined(nimdoc) and not defined(gcDestructors): {.fatal: "mm:arc or mm:orc required".}

# (C) Olli Niinivaara, 2020-2025
# MIT Licensed

## A high level SQLite API with support for multi-threading, prepared statements,
## proper typing, zero-copy data paths, debugging, optimizing, backups, and more.
##
## Example
## =======
##
## .. code-block:: Nim
##
##
##  import sqliteral
##
##  const Schema = "CREATE TABLE IF NOT EXISTS Example(name TEXT NOT NULL, jsondata TEXT NOT NULL) STRICT"
##
##  type
##    SqlStatements = enum
##      Insert = """INSERT INTO Example (name, jsondata)
##       VALUES (json_extract(?, '$.name'), json_extract(?, '$.data'))"""
##      Select = "SELECT json_extract(jsondata, '$.array') FROM Example"
##
##    ExtraStatements = enum
##      Count = (2, "SELECT count(*) FROM Example")
##      # Statement ordinal values must be unique across all statements
##
##  let json = toDb("""{"name":"Alice", "data":{"info":"xxx", "array":["a","b","c"]}}""")
##
##  var db: SQLiteral
##  when not defined(release): db.setLogger(proc(db: SQLiteral, msg: string, code: int) = echo msg)
##
##  proc select() =
##    {.gcsafe.}:
##      for row in db.rows(Select): stdout.write(row.getCString(0))
##
##  proc run() =
##    echo "inserting 10000 rows..."
##    db.transaction:
##      for i in 1 .. 10000: discard db.insert(Insert, json, json)
##
##    let count = db.getTheInt(Count)
##    echo "10000 more rows inserted."
##    echo "Press <Enter> to select from the all existing ", count, " rows in 4 parallel threads..."
##    discard stdin.readChar()
##
##    var thr: array[4, Thread[void]]
##    for i in 0..high(thr): createThread(thr[i], select)
##    joinThreads(thr)
##    stdout.flushFile()
##    echo "\nSelected " & $(4 * count) & " arrays."
##
##  db.openDatabase("ex.db", Schema)
##  run()
##  db.close()
##
##
## Compiling with sqlite3.c
## ========================
##
## | First, sqlite3.c amalgamation must be on compiler search path.
## | You can extract it from a zip available at https://www.sqlite.org/download.html.
## | Then, `-d:staticSqlite`compiler option must be used.
##
## For your convenience, `-d:staticSqlite` triggers some useful SQLite compiler options,
## consult sqliteral source code or `about()` proc for details.
## These can be turned off with `-d:disableSqliteoptions` option.
##
## Statements in enum lists
## ========================
##
## SQLiteral prepares statements only once, and their ordinal value in their corresponding enum
## list is used internally for indexing. Therefore, if you use statements from more than
## one enum list, the enums in other lists must be explicitly given unique ordinal values. The
## example above demonstrates this, where value 2 is set for the Count statement (Insert and
## Select implicitly get the values 0 and 1).

when defined(staticSqlite): {.passL: "-lpthread".}
else:
  when defined(windows):
    when defined(nimOldDlls):
      const Lib = "sqlite3.dll"
    elif defined(cpu64):
      const Lib = "sqlite3_64.dll"
    else:
      const Lib = "sqlite3_32.dll"
  elif defined(macosx):
    const Lib = "libsqlite3(|.0).dylib"
  else:
    const Lib = "libsqlite3.so(|.0)"

when defined(staticSqlite) and not defined(disableSqliteoptions):
  {.passC: "-DSQLITE_DQS=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_LIKE_DOESNT_MATCH_BLOBS".}
  {.passC: "-DSQLITE_ENABLE_JSON1 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_PROGRESS_CALLBACK".}
  when defined(danger):
    {.passC: "-DSQLITE_USE_ALLOCA -DSQLITE_MAX_EXPR_DEPTH=0".}

import db_connector/sqlite3
export PStmt, errmsg, reset, step, finalize, SQLITE_ROW
import locks
from os import getFileSize
from strutils import strip, split, contains, replace

const
  MaxStatements* {.intdefine.} = 200
    ## Compile time define pragma that limits amount of prepared statements
  MaxDatabases* {.intdefine.} = 2
    ## Compile time define pragma that limits amount of databases


type
  SQLError* = ref object of CatchableError
    ## https://www.sqlite.org/rescode.html
    rescode*: int

  SQLiteral* = object
    sqlite*: PSqlite3
    dbname*: string
    inreadonlymode*: bool
    backupsinprogress*: int
    index: int
    intransaction: bool
    walmode: bool
    maxsize: int
    transactionlock: Lock
    loggerproc: proc(sqliteral: SQLiteral, statement: string, errorcode: int) {.gcsafe, raises: [].}
    oncommitproc: proc(sqliteral: SQLiteral) {.gcsafe, raises: [].}
    maxparamloggedlen: int
    Transaction: PStmt
    Commit: PStmt
    Rollback: PStmt

  DbValueKind = enum
    sqliteInteger,
    sqliteReal,
    sqliteText,
    sqliteBlob

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
      textVal*: tuple[chararray: cstring, len: int32]
    of sqliteBlob:
      blobVal*: seq[byte] # TODO: openArray[byte]

var
  openlock: Lock
  nextdbindex = 0
  preparedstatements {.threadvar.} : array[MaxDatabases * MaxStatements, PStmt]
  allpreparedstatements: seq[ptr array[MaxDatabases * MaxStatements, PStmt]]


initLock(openlock)


template checkRc*(db: SQLiteral, resultcode: int) =
  ## | Raises SQLError if resultcode notin SQLITE_OK, SQLITE_ROW, SQLITE_DONE
  ## | https://www.sqlite.org/rescode.html
  if resultcode notin [SQLITE_OK, SQLITE_ROW, SQLITE_DONE]:
    let errormsg =
      if resultcode == 10000: "Sqliteral error"
      else: $errmsg(db.sqlite)
    if db.loggerproc != nil: db.loggerproc(db, errormsg, resultcode)
    raise SQLError(msg: db.dbname & " " & errormsg, rescode: resultcode)


proc toDb*(val: cstring, len = -1): DbValue {.inline.} =
  if len == -1: DbValue(kind: sqliteText, textVal: (val, int32(val.len())))
  else: DbValue(kind: sqliteText, textVal: (val, int32(len)))

proc toDb*(val: cstring, first, last: int): DbValue {.inline.} =
  DbValue(kind: sqliteText, textVal: (cast[cstring](unsafeAddr(val[first])), int32(1 + last - first)))

proc toDb*(val: string, len = -1): DbValue {.inline.} =
  if len == -1: DbValue(kind: sqliteText, textVal: (cstring(val), int32(val.len())))
  else: DbValue(kind: sqliteText, textVal: (cstring(val), int32(len)))

proc toDb*(val: string, first, last: int): DbValue {.inline.} =
  DbValue(kind: sqliteText, textVal: (cast[cstring](unsafeAddr(val[first])), int32(1 + last - first)))

{.warning[PtrToCstringConv]:off.}
proc toDb*(val: openArray[char], len = -1): DbValue {.inline.} =
  if len == -1: DbValue(kind: sqliteText, textVal: (cstring(unsafeAddr val[0]), int32(val.len())))
  else: DbValue(kind: sqliteText, textVal: (cstring(unsafeAddr val[0]), int32(len)))
{.warning[PtrToCstringConv]:on.}

proc toDb*[T: Ordinal](val: T): DbValue {.inline.} = DbValue(kind: sqliteInteger, intVal: val.int64)

proc toDb*[T: SomeFloat](val: T): DbValue {.inline.} = DbValue(kind: sqliteReal, floatVal: val.float64)

proc toDb*(val: seq[byte]): DbValue {.inline.} = DbValue(kind: sqliteBlob, blobVal: val)

proc toDb*[T: DbValue](val: T): DbValue {.inline.} = val


proc `$`*[T: DbValue](val: T): string {.inline.} =
  case val.kind
  of sqliteInteger: $val.intVal
  of sqliteReal: $val.floatVal
  of sqliteText: ($val.textVal.chararray)[0 .. val.textVal.len - 1]
  of sqliteBlob: cast[string](val.blobVal)


proc prepareSql*(db: SQLiteral, sql: cstring): PStmt {.inline.} =
  ## Prepares a cstring into an executable statement
  checkRc(db, prepare_v2(db.sqlite, sql, sql.len.cint, result, nil))
  return result


proc getStatement(db: SQLiteral, statement: enum): PStmt =
  result = preparedstatements[db.index * MaxStatements + ord(statement)]
  if likely(result != nil): return result
  let index = ord(statement)
  if unlikely(index >= MaxStatements):
    let problem = "Index " & $index & " of '" & $statement & "' larger than MaxStatements = " & $MaxStatements
    if db.loggerproc != nil: db.loggerproc(db, problem, 10000)
    raise SQLError(msg: db.dbname & " " & problem, rescode: 10000)
  result = prepareSql(db, ($statement).cstring)
  preparedstatements[db.index * MaxStatements + index] = result
  if not allpreparedstatements.contains(addr preparedstatements):
    allpreparedstatements.add(addr preparedstatements)
  if db.loggerproc != nil:
    db.loggerproc(db, "Prepared for thread " & $getThreadId() & ": " & $statement, -1)


proc bindParams*(sql: PStmt, params: varargs[DbValue]): int {.inline.} =
  var idx = 1.int32
  for value in params:
    result =
      case value.kind
      of sqliteInteger: bind_int64(sql, idx, value.intVal)
      of sqliteReal: bind_double(sql, idx, value.floatVal)
      of sqliteText: bind_text(sql, idx, value.textVal.chararray, value.textVal.len, SQLITE_STATIC)
      of sqliteBlob: bind_blob(sql, idx.int32, cast[string](value.blobVal).cstring, value.blobVal.len.int32, SQLITE_STATIC)
    if result != SQLITE_OK: return
    idx.inc


template log() =
  var resultcode = 0
  var logstring = $statement
  var replacement = 0
  while replacement < params.len:
    let position = logstring.find('?')
    if (position == -1):
      logstring = $params.len & "is too many params for: " & $statement
      replacement = params.len
      resultcode = 10000
      continue
    let param =
      if db.maxparamloggedlen < 1: $params[replacement]
      else: ($params[replacement]).substr(0, db.maxparamloggedlen - 1)
    logstring = logstring[0 .. position-1] & param & logstring.substr(position+1)
    replacement += 1
  if (logstring.find('?') != -1):
    logstring &= " (some params missing)"
    resultcode = 10000
  db.loggerproc(db, logstring, resultcode)


proc doLog*(db: SQLiteral, statement: string, params: varargs[DbValue, toDb]) {.inline.} =
  if statement == "Pstmt rows" or statement == "exec Pstmt": db.loggerproc(db, statement & " " & $params, 0)
  else: log()

#-----------------------------------------------------------------------------------------------------------

proc getInt*(prepared: PStmt, col: int32 = 0): int64 {.inline.} =
  ## Returns value of INTEGER -type column at given column index
  return column_int64(prepared, col)


proc getString*(prepared: PStmt, col: int32 = 0): string {.inline.} =
  ## Returns value of TEXT -type column at given column index as string
  return $column_text(prepared, col)


proc getCString*(prepared: PStmt, col: int32 = 0): cstring {.inline.} =
  ## | Returns value of TEXT -type column at given column index as cstring.
  ## | Zero-copy, but result is not available after cursor movement or statement reset.
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


proc getAsStrings*(prepared: PStmt): seq[string] =
  ## Returns values of all result columns as a sequence of strings.
  ## This proc is mainly useful for debugging purposes.
  let columncount = column_count(prepared)
  for col in 0 ..< columncount: result.add($column_text(prepared, col))


iterator rows*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb]): PStmt =
  ## Iterates over the query results
  if db.loggerproc != nil: log()
  let s = db.getStatement(statement)
  checkRc(db, bindParams(s, params))
  defer: discard sqlite3.reset(s)
  while step(s) == SQLITE_ROW: yield s


iterator rows*(db: SQLiteral, pstatement: Pstmt, params: varargs[DbValue, toDb]): PStmt =
  ## Iterates over the query results
  if db.loggerproc != nil: db.doLog("Pstmt rows", params)
  checkRc(db, bindParams(pstatement, params))
  defer: discard sqlite3.reset(pstatement)
  while step(pstatement) == SQLITE_ROW: yield pstatement


proc getTheInt*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb]): int64 {.inline.} =
  ## | Executes query and returns value of INTEGER -type column at column index 0 of first result row.
  ## | If query does not return any rows, returns -2147483647 (low(int32) + 1).
  ## | Automatically resets the statement.
  if db.loggerproc != nil: log()
  let s = db.getStatement(statement)
  checkRc(db, bindParams(s, params))
  defer: discard sqlite3.reset(s)
  if step(s) == SQLITE_ROW: s.getInt(0) else: -2147483647


proc getTheInt*(db: SQLiteral, s: string): int64 {.inline.} =
  ## | Dynamically prepares, executes and finalizes given query and returns value of INTEGER -type
  ## column at column index 0 of first result row.
  ## | If query does not return any rows, returns -2147483647 (low(int32) + 1).
  ## | For security and performance reasons, this proc should be used with caution.
  if db.loggerproc != nil: db.loggerproc(db, s, 0)
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
  if db.loggerproc != nil: log()
  let s = db.getStatement(statement)
  checkRc(db, bindParams(s, params))
  defer: discard sqlite3.reset(s)
  if step(s) == SQLITE_ROW: return s.getString(0)


proc getTheString*(db: SQLiteral, s: string): string {.inline.} =
  ## | Dynamically prepares, executes and finalizes given query and returns value of TEXT -type
  ## column at column index 0 of first result row.
  ## | If query does not return any rows, returns empty string.
  ## | For security and performance reasons, this proc should be used with caution.
  if db.loggerproc != nil: db.loggerproc(db, s, 0)
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
  if db.loggerproc != nil: log()
  let s = db.getStatement(statement)
  checkRc(db, bindParams(s, params))
  defer: discard sqlite3.reset(s)
  return step(s) == SQLITE_ROW


proc rowExists*(db: SQLiteral, sql: string): bool {.inline.} =
  ## | Returns true if query returns any rows.
  ## | For security reasons, this proc should be used with caution.
  if db.loggerproc != nil: db.loggerproc(db, sql, 0)
  let preparedstatement = db.prepareSql(sql.cstring)
  defer: discard finalize(preparedstatement)
  return step(preparedstatement) == SQLITE_ROW


template withRow*(db: SQLiteral, sql: string, row, body: untyped) =
  ## | Dynamically prepares and finalizes an sql query.
  ## | Name for the resulting prepared statement is given with row parameter.
  ## | The code block will be executed only if query returns a row.
  ## | For security and performance reasons, this proc should be used with caution.
  if db.loggerproc != nil: db.loggerproc(db, sql, 0)
  let preparedstatement = prepareSql(db, sql.cstring)
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
  ## | For security and performance reasons, this proc should be used with caution.
  ## **Example:**
  ##
  ## .. code-block:: Nim
  ##
  ##  db.withRowOr("SELECT (1) FROM sqlite_master", rowname):
  ##    echo "database has some tables because first column = ", rowname.getInt(0)
  ##  do:
  ##    echo "we have a fresh database"
  ##
  if db.loggerproc != nil: db.loggerproc(db, sql, 0)
  let preparedstatement = prepareSql(db, sql.cstring)
  try:
    if step(preparedstatement) == SQLITE_ROW:
      var row {.inject.} = preparedstatement
      body1
    else: body2
  finally:
    discard finalize(preparedstatement)


template withRow*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb], row, body: untyped) =
  ## | Executes given statement.
  ## | Name for the prepared statement is given with row parameter.
  ## | The code block will be executed only if query returns a row.
  if db.loggerproc != nil: doLog(db, $statement, params)
  let s = db.getStatement(statement)
  defer: discard reset(s)
  checkRc(db, bindParams(s, params))
  if step(s) == SQLITE_ROW:
    var row {.inject.} = s
    body


template withRowOr*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb], row, body1, body2: untyped) =
  ## | Executes given statement.
  ## | Name for the prepared statement is given with row parameter.
  ## | First block will be executed if query returns a row, otherwise the second block.
  if db.loggerproc != nil: doLog(db, $statement, params)
  let s = db.getStatement(statement)
  checkRc(db, bindParams(s, params))
  try:
    if step(s) == SQLITE_ROW:
      var row {.inject.} = s
      body1
    else: body2
  finally:
    discard sqlite3.reset(s)

#-----------------------------------------------------------------------------------------------------------

proc exec*(db: SQLiteral, pstatement: Pstmt, params: varargs[DbValue, toDb]) {.inline.} =
  ## Executes given prepared statement
  if db.loggerproc != nil: db.doLog("exec Pstmt", params)
  defer: discard sqlite3.reset(pstatement)
  checkRc(db, bindParams(pstatement, params))
  checkRc(db, step(pstatement))


proc exec*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb]) {.inline.} =
  ## Executes given statement
  if db.loggerproc != nil: log()
  let s = db.getStatement(statement)
  defer: discard sqlite3.reset(s)
  checkRc(db, bindParams(s, params))
  checkRc(db, step(s))


proc exes*(db: SQLiteral, sql: string) =
  ## | Prepares, executes and finalizes given semicolon-separated sql statements.
  ## | For security and performance reasons, this proc should be used with caution.
  if db.loggerproc != nil: db.loggerproc(db, sql, -1)
  var errormsg: cstring
  let rescode = sqlite3.exec(db.sqlite, sql.cstring, nil, nil, errormsg)
  if rescode != 0:
    var error: string
    if errormsg != nil:
      error = $errormsg
      free(errormsg)
    if db.loggerproc != nil: db.loggerproc(db, error, rescode)
    raise SQLError(msg: db.dbname & " " & $rescode & " " & error, rescode: rescode)


proc insert*(db: SQLiteral, statement: enum, params: varargs[DbValue, toDb]): int64 {.inline.} =
  ## | Executes given statement and, if succesful, returns db.getLastinsertRowid().
  ## | If not succesful, returns -2147483647 (low(int32) + 1).
  if db.loggerproc != nil: log()
  let s = db.getStatement(statement)
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
  if db.loggerproc != nil: db.loggerproc(db, $update & " (" & $newvalue & ", " & $where & ")", 0)
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
  if db.loggerproc != nil: db.loggerproc(db, $sql, 0)
  let pstmt = db.prepareSql(sql)
  try:
    if step(pstmt) == SQLITE_ROW: result = pstmt.getInt(0) == 1
  finally:
    discard sqlite3.reset(pstmt)
    discard pstmt.finalize()


template transaction*(db: var SQLiteral, body: untyped) =
  ## | Every write to database must happen inside some transaction.
  ## | Groups of reads must be wrapped in same transaction if mutual consistency required.
  ## | In WAL mode (the default), independent reads must NOT be wrapped in transaction to allow parallel processing.
  if not db.inreadonlymode:
    acquire(db.transactionlock)
    exec(db, db.Transaction)
    db.intransaction = true
    if db.loggerproc != nil: db.loggerproc(db, "--- BEGIN TRANSACTION", 0)
    try: body
    except CatchableError as ex:
      exec(db, db.Rollback)
      if db.loggerproc != nil: db.loggerproc(db, "--- ROLLBACK", 0)
      db.intransaction = false
      raise ex
    finally:
      if db.intransaction:
        exec(db, db.Commit)
        if db.oncommitproc != nil: db.oncommitproc(db)
        db.intransaction = false
        if db.loggerproc != nil: db.loggerproc(db, "--- COMMIT", 0)
      release(db.transactionlock)


template transactionsDisabled*(db: var SQLiteral, body: untyped) =
  ## Executes `body` in between transactions (ie. does not start transaction, but transactions are blocked during this operation).
  acquire(db.transactionlock)
  if db.loggerproc != nil: db.loggerproc(db, "--- TRANSACTIONS DISABLED", 0)
  try:
    body
  finally:
    if db.loggerproc != nil: db.loggerproc(db, "--- TRANSACTIONS ENABLED", 0)
    release(db.transactionlock)


proc isIntransaction*(db: SQLiteral): bool {.inline.} =
  return db.intransaction


proc setLogger*(db: var SQLiteral, logger: proc(sqliteral: SQLiteral, statement: string, code: int)
 {.gcsafe, raises: [].}, paramtruncat = 50) =
  ## Set callback procedure to gather all executed statements with their parameters.
  ##
  ## If code == 10000, log concerns internal sqliteral error.
  ##
  ## If code > 0, log concerns sqlite error with error code in question.
  ##
  ## If code == 0, log concerns normal operation.
  ##
  ## If code == -1, log is mainly for debugging purposes.
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

# -------------------------------------------------------------------------------------------------------------

proc openDatabase*(db: var SQLiteral, dbname: string, schemas: openArray[string],
 maxKbSize = 0, wal = true, ignorableschemaerrors: openArray[string] = @["duplicate column name", "no such column"]) =
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
  ## `ignorableschemaerrors` is a list of error message snippets for sql errors that are to be ignored.
  ## If a clause may error, it must be given in a separate schema as its unique clause.
  ## If * is given as ignorable error, it means that all errors will be ignored.
  ##
  ## Note that by default, "duplicate column name" (ADD COLUMN) and "no such column" (DROP COLUMN) -errors will be ignored.
  ## Example below.
  ##
  ## .. code-block:: Nim
  ##
  ##  # nim r -d:Maxdatabases=4 example.nim
  ##  import sqliteral
  ##
  ##  const
  ##    Schema1 = "CREATE TABLE IF NOT EXISTS Example(data TEXT NOT NULL) STRICT"
  ##    Schema2 = "this is crap"
  ##    Schema3 = "ALTER TABLE Example ADD COLUMN newcolumn TEXT"
  ##    Schema4 = "ALTER TABLE Example ADD COLUMN newcolumn TEXT"
  ##
  ##  var db1, db2, db3: SQLiteral
  ##
  ##  proc logger(db: SQLiteral, msg: string, code: int) = echo msg
  ##  db1.setLogger(logger); db2.setLogger(logger); db3.setLogger(logger)
  ##
  ##  # this will succeed because extra ADD COLUMNs are ignored:
  ##  db1.openDatabase("example1.db", [Schema1, Schema3, Schema4]); db1.close()
  ##
  ##  # this will succeed because suitable ignorableschemaerrors are given:
  ##  db2.openDatabase("example2.db", [Schema1, Schema2],
  ##    ignorableschemaerrors = ["""this": syntax error"""]); db2.close()
  ##
  ##  # this will succeed because all schema errors are ignored:
  ##  db3.openDatabase("example1.db", [Schema1, Schema2, Schema3],
  ##    ignorableschemaerrors = ["*"]); db3.close()
  ##
  ##  # this will fail because Schema 2 has syntax error:
  ##  db1.openDatabase("example1.db", [Schema1, Schema2])
  ##
  doAssert dbname != ""
  withLock(openlock):
    if nextdbindex == MaxDatabases: raiseAssert("Cannot open more than " & $MaxDatabases & " databases. Increase the MaxDatabases intdefine.")
    db.index = nextdbindex
    nextdbindex += 1
  initLock(db.transactionlock)
  db.dbname = dbname
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
  for schema in schemas:
    try: db.exes(schema)
    except:
      var ignorable = false
      for ignorableerror in ignorableschemaerrors:
        if ignorableerror == "*" or getCurrentExceptionMsg().contains(ignorableerror): (ignorable = true; break)
      if not ignorable: raise
  db.Transaction = db.prepareSql("BEGIN IMMEDIATE".cstring)
  db.Commit = db.prepareSql("COMMIT".cstring)
  db.Rollback = db.prepareSql("ROLLBACK".cstring)
  if db.loggerproc != nil: db.loggerproc(db, db.dbname & " opened", -1)


proc openDatabase*(db: var SQLiteral, dbname: string, schema: string, maxKbSize = 0, wal = true) {.inline.} =
  ## Open database with a single schema.
  openDatabase(db, dbname, [schema], maxKbSize, wal, @["duplicate column name", "no such column"])


proc prepareStatements*(db: var SQLiteral, statements: typedesc[enum]) {.deprecated: "Preparations happen automatically.".} = discard
proc finalizeStatements*() {.deprecated: "Finalizations happen automatically.".} = discard


proc finalizeAllStatements() =
  for threadpreparedstatements in allpreparedstatements:
    for i in 0 .. threadpreparedstatements[].high:
      if threadpreparedstatements[][i] != nil:
        discard threadpreparedstatements[][i].finalize()
        threadpreparedstatements[][i] = nil


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
    if db.loggerproc != nil: db.loggerproc(db, "--- READONLY MODE: " & $readonly , 0)


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
    if db.loggerproc != nil: db.loggerproc(db, getCurrentExceptionMsg(), 10000)
    else: echo "Could not optimize ", db.dbname, ": ", getCurrentExceptionMsg()
  finally:
    release(db.transactionlock)


proc initBackup*(db: var SQLiteral, backupfilename: string):
 tuple[backupdb: Psqlite3, backuphandle: PSqlite3_Backup] =
  ## Initializes backup processing, returning variables to use with `stepBackup` proc.
  ##
  ## Note that `close` will fail with SQLITE_BUSY if there's an unfinished backup process going on.
  db.checkRc(open(backupfilename, result.backupdb))
  db.transactionsDisabled:
    result.backuphandle = backup_init(result.backupdb, "main".cstring, db.sqlite, "main".cstring)
    if result.backuphandle == nil: db.checkRc(SQLITE_NULL)
    elif db.loggerproc != nil: db.loggerproc(db, "backup to " & backupfilename, 0)
    discard db.backupsinprogress.atomicInc


proc stepBackup*(db: var SQLiteral, backupdb: Psqlite3, backuphandle: PSqlite3_Backup, pagesperportion = 5.int32): int =
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
    discard db.backupsinprogress.atomicDec
    if db.loggerproc != nil: db.loggerproc(db, "backup ok", 0)
    return 100
  if rc notin [SQLITE_OK, SQLITE_BUSY, SQLITE_LOCKED]:
    discard db.backupsinprogress.atomicDec
    if db.loggerproc != nil: db.loggerproc(db, "backup failed", rc)
    discard backup_finish(backuphandle)
    discard backupdb.close()
    db.checkRc(rc)
  return 100 * (backuphandle.backup_pagecount - backuphandle.backup_remaining) div backuphandle.backup_pagecount


proc cancelBackup*(db: var SQLiteral, backupdb: Psqlite3, backuphandle: PSqlite3_Backup) =
  ## Cancels an ongoing backup process.
  if unlikely(backupdb == nil or backuphandle == nil): db.checkRc(SQLITE_NULL)
  discard backup_finish(backuphandle)
  discard backupdb.close()
  discard db.backupsinprogress.atomicDec
  if db.loggerproc != nil: db.loggerproc(db, "backup canceled", 0)


proc inMemory(db: SQLiteral): bool =
  db.dbname == ":memory:"


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
  if not db.inMemory:
    let filesize = getFileSize(db.dbname)
    echo "Filesize=", filesize
    if db.maxsize > 0:
      echo "Maxsize=", db.maxsize * 1024
      echo "Sizeused=", (filesize div ((db.maxsize.float * 10.24).int)), "%"
  echo ""


when defined(staticSqlite):
  proc db_status(db: PSqlite3, op: int32, cur: ptr int32, highest: ptr int32, reset: int32): int32 {.cdecl, importc: "sqlite3_db_status".}
else:
  proc db_status(db: PSqlite3, op: int32, cur: ptr int32, highest: ptr int32, reset: int32): int32 {.cdecl, dynlib: Lib, importc: "sqlite3_db_status".}


proc getStatus*(db: SQLiteral, status: int, resethighest = false): (int, int) =
  ## Retrieves queried status info.
  ## See https://www.sqlite.org/c3ref/c_dbstatus_options.html
  ##
  ## **Example:**
  ##
  ## .. code-block:: Nim
  ##
  ##    const SQLITE_DBSTATUS_CACHE_USED = 1
  ##    echo "current cache usage: ", db.getStatus(SQLITE_DBSTATUS_CACHE_USED)[0]
  var c, h: int32
  db.checkRc(db_status(db.sqlite, status.int32, addr c, addr h, resethighest.int32))
  return (c.int, h.int)


when defined(staticSqlite):
  proc callInterrupt(db: PSqlite3) {.cdecl, importc: "sqlite3_interrupt".}
else:
  proc callInterrupt(db: PSqlite3) {.cdecl, dynlib: Lib, importc: "sqlite3_interrupt".}

proc interrupt*(db: var SQLiteral) =
  ## Interrupts long running operations by calling https://www.sqlite.org/c3ref/interrupt.html
  callInterrupt(db.sqlite)


proc close*(db: var SQLiteral) =
  ## Closes the database.
  if db.Transaction == nil:
    if db.loggerproc != nil: db.loggerproc(db, "already closed: " & db.dbname, 10000)
    return
  if db.backupsinprogress > 0:
    raise SQLError(msg: "Cannot close, backups still in progress: " & $db.backupsinprogress, rescode: SQLITE_BUSY)
  var rc = 0
  acquire(db.transactionlock)
  try:
    discard db.Transaction.finalize()
    discard db.Commit.finalize()
    discard db.Rollback.finalize()
    finalizeAllStatements()
    rc = close(db.sqlite)
    if rc == SQLITE_OK:
      db.Transaction = nil
      if db.loggerproc != nil: db.loggerproc(db, db.dbname & " closed", 0)
    else: db.checkRc(rc)
  except:
    if db.loggerproc != nil: db.loggerproc(db, getCurrentExceptionMsg(), 10000)
    raise SQLError(msg: getCurrentExceptionMsg(), rescode: 10000)
  finally:
    release(db.transactionlock)
    if db.Transaction == nil: deinitLock(db.transactionlock)
