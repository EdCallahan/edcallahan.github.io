---
layout: default
title: Methodology
nav_order: 2
parent: SyncTables-NoPK Procedure
grand_parent: SQL
---

# Methodology

To demonstrate the methodology SyncTables-NoPK uses, we use two example source and destination tables. We will want to update dbo.[Destination] so it has the same contents as dbo.[Source] after SyncTables runs.

The SQL to create these tables and execute the following commands is at [Download methodology.sql](./methodology.sql).

## dbo.[Source] table

<div class="table-boxed" markdown="1">

| ID   | FirstName | LastName | Department |
|:-----|:--------- |:-------- |:-----------|
| NULL | Oscar     | Martinez | Accounting |
| NULL | Phyllis   | Vance    | Sales      |
| NULL | Stanley   | Hudson   | Sales      |
| NULL | Michael   | Scott    | Corporate  |

</div>

## dbo.[Destination] table

| ID | FirstName | LastName | Department |
|:---|:----------|:---------|:-----------|
| 1  | Kevin     | Malone   | Accounting |
| 2  | Oscar     | Martinez | Corporate  |
| 3  | Stanley   | Hudson   | NULL       |
| 4  | Michael   | Scott    | Corporate  |

*Note:* The primary key of dbo.[Destination] is the ID field

## Prepare dbo.[Source]

We need to number the records in the dbo.[Source] table so that they are always larger than the values in the dbo.[Destination] table. We use this structure to determine which records 
need to be inserted or deleted in dbo.[Destination].

```sql
declare @maxid int = (select isnull(max(ID), 0) from dbo.[Destination])

declare @id int = @maxid
update dbo.[Source] set @id = ID = @id+1 option (maxdop 1)

select * from dbo.[Source]
```

| ID | FirstName | LastName | Department |
|:---|:----------|:---------|:-----------|
| 5  | Oscar     | Martinez | Accounting |
| 6  | Phyllis   | Vance    | Sales      |
| 7  | Stanley   | Hudson   | Sales      |
| 8  | Michael   | Scott    | Corporate  |


*NOTE:* the maxdop compiler hint is essential here. If the SQL engine multi-threads the UPDATE, the ID numbers will not be unique.


## Compare Source to Destination

Now, we use the UNION statement to compare these tables:

```sql
select max(ID) ID, FirstName, LastName, Department
into #updates
from (
    select ID, FirstName, LastName, Department from dbo.Source
    union
    select ID, FirstName, LastName, Department from dbo.Destination
) t
group by FirstName, LastName, Department
having count(*)=1

select * from #updates
```

| ID | FirstName | LastName | Department |
|:---|:----------|:---------|:-----------|
| 1  | Kevin     | Malone   | Accounting |
| 2  | Oscar     | Martinez | Corporate  |
| 3  | Stanley   | Hudson   | NULL       |
| 5  | Oscar     | Martinez | Accounting |
| 6  | Phyllis   | Vance    | Sales      |
| 7  | Stanley   | Hudson   | Sales      |


Notice that Michael Scott does not appear in the output. The name and department for him are the same in both dbo.[Source] and dbo.[Destination], so we exclude those records since they don't need changes.
The HAVING clause handles this. This is where the requirement that the records in dbo.[Source] all be unique, without duplicate rows.

Of the remaining, those with ID of 4 or less are from the dbo.[Destination] table and need to be need to be deleted from dbo.[Destination]. 
Those with ID greater than 4 need to be inserted into dbo.[Destination].

## Use results above to Insert and Delete

Only two SQL commands are needed to update the Destination table:

### Insert
```sql
insert into dbo.Destination (ID, FirstName, LastName, Department) 
select ID, FirstName, LastName, Department
    from #updates
    where ID > (select max(ID) from dbo.Destination)
```

### Delete

```sql
delete dbo.Destination 
    from dbo.Destination a
    join #updates b
    on a.ID=b.ID
```

## Implementing Methodology in dbo.SyncTables

* The primary key columns and not-PK columns are determined by SQL metadata tables
* Dynamic SQL is used to build and execute the SQL queries outlined above using that metadata
* We use tables in a tmp_sync schema instead of temp tables used above, since temp tables such as #updates aren't available from within dynamic SQL calls
* In a high usage scenario where SyncTables is running concurrently and syncing several tables at once, the dropping and recreating of the tmp_sync tables has lead to deadlock issues on low level SQL Server tables. In these situations we have adjusted SyncTable to never delete the tmp_sync tables, and only create them when needed. In this case we empty the tables and repopulate them with the EXCEPT/UNION query results on each run instead.
* Transactions are used to make sure the INSERT/UPDATE/DELETE commands succeed or fail as a group, handling the fact the SyncTables may be called from within an outer transaction
