---
layout: default
title: SyncTables Procedure
nav_order: 1
parent: SQL
---

# SyncTables Procedure

`SyncTables` is a stored procedure that updates a destination table from a source table with an INSERT, UPDATE and DELETE statement, as needed. It relies on the SQL UNION and EXCEPT statements to compare the two tables, which:

* Are highly performant, and
* Handle NULLs well for this purpose without the need for ISNULL() and similar tricks to compare NULLs to non-NULL values

`SyncTables` will update the destination table with a maximum of three SQL commands, one each for INSERT, UPDATE and DELETE, making it fast and efficient. Minimizing the number of calls to update the table, and to ensure only records that need updates are updated, become important for temporal tables and tables used in SQL Replication, for instance.

Requirements for this procedure to work are:

* The destination table must have a primary key set on it
* The primary key columns must also exist in the source table (but don't have to comprise a primary key)
* A tmp_sync schema must exist in the database SyncTables is found in

Notes:

* Only columns found in both the source and destination tables will be updated, and the types of these columns must match

