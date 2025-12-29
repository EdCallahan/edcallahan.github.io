---
layout: default
title: SyncTables Procedure
nav_order: 1
parent: SQL
---

# SyncTables Procedure

`SyncTables` is a stored procedure that updates a destination table from a source table with an INSERT, UPDATE and DELETE statement, as needed. It relies on the SQL EXCEPT statement to compare the two tables, which:

* Is highly performant, and
* Handles NULLs well for this purpose

Requirements for this procedure to work are:

* The destination table must have a primary key set on it
* The primary key columns must also exist in the source table (but don't have to comprise a primary key)
* A tmp_sync schema must exist in the database SyncTables is found in

Notes:

* Only columns found in both the source and destination tables will be updated, and the types of these columns must match