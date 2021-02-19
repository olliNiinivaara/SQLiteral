# SQLiteral
A high level SQLite API for Nim

Supports multi-threading, prepared statements, proper typing, zero-copy string views,
state syncing, debugging executed statements, static binding to sqlite3.c of your choice, optimizing, and more

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