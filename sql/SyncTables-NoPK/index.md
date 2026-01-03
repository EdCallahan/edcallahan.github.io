---
layout: default
title: SyncTables-NoPK Procedure
nav_order: 2
parent: SQL
---

# SyncTables-NoPK Procedure

`SyncTables-PK` is a stored procedure that updates a destination table from a source table with an INSERT and DELETE statement, as needed, when the tables have no primary key defined. It relies on the SQL UNION statement to compare the two tables, which:

* Is highly performant, and
* Handles NULLs well for this purpose without the need for ISNULL() and similar tricks to compare NULLs to non-NULL values

`SyncTables-PK` will update the destination table with a maximum of two SQL commands, one each for INSERT and DELETE, making it fast and efficient. Minimizing the number of calls to update the table, and to ensure only records that need updates are updated, become important for temporal tables and tables used in SQL Replication, for instance.

Requirements for this procedure to work are:

* Even though the tables to not have a native primary key, we need to introduce one. The destination table must have a primary key set on it with a single element of type INT.
* A column of with the same name and type must also exist in the source table (but don't have to be defined as a primary key)
* The source table records must all be unique and no two have the same values
* A tmp_sync schema must exist in the database SyncTables-NoPK is found in

Notes:

* Only columns found in both the source and destination tables will be updated, and the types of these columns must match

