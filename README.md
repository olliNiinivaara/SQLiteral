# SQLiteral
A high level SQLite API for Nim

Supports multi-threading, prepared statements, proper typing, zero-copy string views,
state syncing, debugging executed statements, static binding to sqlite3.c of your choice, optimizing, and more

## Documentation
http://htmlpreview.github.io/?https://github.com/olliNiinivaara/SQLiteral/blob/master/doc/sqliteral.html

## Installation
`nimble install sqliteral`

## Change log

**1.2.0 (2020-11-23)**
* requires nim 1.4.0+ (older versions might work too, but not tested)
* supports string views with --experimental:views compile flag
* onCommitCallback
* Text deprecated
* partition states deprecated

## Roadmap

**1.3.0**
* backups in background thread: https://sqlite.org/backup.html example 2
* remove partition states

**1.4.0** https://www.sqlite.org/json1.html

**2.0.0** When views become officially supported in nim, remove Text