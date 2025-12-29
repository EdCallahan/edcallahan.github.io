---
layout: default
title: Methodology
nav_order: 2
parent: SyncTables Procedure
grand_parent: SQL
---

# Methodology

To demonstrate the methodology SyncTables uses, we use two example source and destination tables. We will want to update dbo.[Destination] so it has the same contents as dbo.Sourse after SyncTables runs.

The SQL to create these tables and execute the following commands is at [methodology.sql](./methodology.sql).

## dbo.[Source] table

|FirstName	| LastName	| Department |
|:----------|:----------|:-----------|
|Oscar	    | Martinez	| Accounting |
|Phyllis	| Vance	    | Sales      |
|Stanley	| Hudson	| Sales      |

*Note:* The primary key of dbo.[Source] is a compsite key of FirstName and LastName

## dbo.[Destination] table

|FirstName	| LastName	| Department |
|:----------|:----------|:-----------|
|Kevin	    | Malone	| Accounting |
|Oscar	    | Martinez	| Corporate  |
|Stanley	| Hudson	| NULL       |

## Compare Source to Destinaction

Now, we use the EXCEPT statement to compare these tables. We do this twice, comparing Source to Destination and the Destination to Source:

```sql
select [FirstName], [LastName], [Department] from dbo.[Source]
except
select [FirstName], [LastName], [Department] from dbo.[Destination]
```


|FirstName	| LastName	| Department |
|:----------|:----------|:-----------|
|Oscar	    | Martinez	| Accounting |
|Phyllis	| Vance	    | Sales      |
|Stanley	| Hudson	| Sales      |


These results include:

* Phyllis who needs to be added to dbo.[Destination]
* Oscar and Stanley, who need to be updated in dbo.[Destination]

## Compare Destination to Source

```sql
select [FirstName], [LastName], [Department] from dbo.[Destination]
except
select [FirstName], [LastName], [Department] from dbo.[Source]
```


|FirstName	| LastName	| Department |
|:----------|:----------|:-----------|
|Kevin	    | Malone	| Accounting |
|Oscar	    | Martinez	| Corporate  |
|Stanley	| Hudson	| NULL       |

These results include:

* Kevin who needs to be deleted from dbo.[Destination]
* Oscar and Stanley, who need to be updated in dbo.[Destination]


## Determine records that need to be inserted/updated/deleted

We can look at the primary keys in these result sets to determing which records need inserts/updates/deletes for each primary key combination:

```sql
select FirstName, LastName, count(*) RecCount, max([Table]) [Table]
    into #updates
    from (
        select 'Source' [Table], [FirstName], [LastName], [Department] from dbo.[Source]
        except
        select 'Source' [Table], [FirstName], [LastName], [Department] from dbo.[Destination]

        union all

        select 'Destination' [Table], [FirstName], [LastName], [Department] from dbo.[Destination]
        except
        select 'Destination' [Table], [FirstName], [LastName], [Department] from dbo.[Source]
    ) t
    group by FirstName, LastName

select * from #updates
```

|FirstName	| LastName	|   RecCount	| Table         |
|:----------|:----------|:--------------|:--------------|
|Kevin	    | Malone	|   1	        | Destination   |
|Oscar	    | Martinez	|   2	        | Source        |
|Phyllis	| Vance	    |   1	        | Source        |
|Stanley	| Hudson	|   2	        | Source        |

* Oscar and Stanley have a RecCount of 2, these need to be updated in dbo.[Destination]
* Kevin has a RecCount of 1 and Table is "Desitination". He needs to be deleted from the Destination since he's not in the Source. 
* Phyllis has a RecCount of 1 and Table is "Source". She needs to be added to the Destination since she's in the Source. 


## Use results above to Insert/Update/Delete

A total of three SQL commands are needed to update the Destination table:

### Insert
```sql
insert into dbo.[Destination] (FirstName, LastName, Department) 
select a.FirstName, a.LastName, a.Department
    from dbo.[Source] a
    join #updates b
    on a.FirstName=b.FirstName and a.LastName=b.LastName
    where b.RecCount=1 and b.[Table]='Source'
```

### Update

```sql
update dbo.[Destination]
set Department=b.Department
    from #updates a
    join dbo.[Source] b
    on a.FirstName=b.FirstName and a.LastName=b.LastName
    join dbo.[Destination] c
    on a.FirstName=c.FirstName and a.LastName=c.LastName
    where a.RecCount=2
```

### Delete

```sql
delete dbo.[Destination] 
    from dbo.[Destination] a
    join #updates b
    on a.FirstName=b.FirstName and a.LastName=b.LastName
    where b.RecCount=1 and b.[Table]='Destination'
```

## Implementing Methodology in dbo.SyncTables

* The primary key columns and not-PK columns are determined by SQL metadata tables
* Dynamic SQL is used to build and execute the SQL queries outlined above using that metadata
* We use maxdop 1 compiler hint when executing the EXCEPT statements to eliminte multi-threading. We have encountered improper table syncs due to multithreadiong in practice
* We use tables in a tmp_sync schema instead of temp tables used above. We have encountered locking issues in the tempdb when creating and deleting temp tables when many instances of SyncTables are running simultaneously
* Transactions are used to make sure the INSERT/UPDATE/DELETE commands succeed or fail as a group, handling the fact the SyncTables may be called from within an outer transaction
