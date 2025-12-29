use Utils
go

drop table if exists dbo.Source
drop table if exists dbo.Destination
go

create table dbo.Source(
     FirstName varchar(100) NOT NULL
    ,LastName varchar(100) NOT NULL
    ,Department varchar(100)
    ,PRIMARY KEY (FirstName, LastName)
)

create table dbo.Destination(
     FirstName varchar(100) NOT NULL
    ,LastName varchar(100) NOT NULL
    ,Department varchar(100)
    ,PRIMARY KEY (FirstName, LastName)
)

INSERT INTO dbo.Source (FirstName, LastName, Department) VALUES ('Phyllis', 'Vance', 'Sales');
INSERT INTO dbo.Source (FirstName, LastName, Department) VALUES ('Stanley', 'Hudson', 'Sales');
INSERT INTO dbo.Source (FirstName, LastName, Department) VALUES ('Oscar', 'Martinez', 'Accounting');

INSERT INTO dbo.Destination (FirstName, LastName, Department) VALUES ('Kevin', 'Malone', 'Accounting');
INSERT INTO dbo.Destination (FirstName, LastName, Department) VALUES ('Stanley', 'Hudson', NULL);
INSERT INTO dbo.Destination (FirstName, LastName, Department) VALUES ('Oscar', 'Martinez', 'Corporate');


---
--- includes Phyllis who needs to be added to dbo.Destination
--- includes Oscar and Stanley, who need to be updated in dbo.Destination
---

select [FirstName], [LastName], [Department] from dbo.Source
except
select [FirstName], [LastName], [Department] from dbo.Destination

---
--- includes Kevin who needs to be deleted from dbo.Destination
--- includes Oscar and Stanley, who need to be updated in dbo.Destination
---

select [FirstName], [LastName], [Department] from dbo.Destination
except
select [FirstName], [LastName], [Department] from dbo.Source

---
--- Oscar and Stanley have a RecCount of 2, these need to be updated in dbo.Destination
--- Kevin has a RecCount of 1 and Table is "Desitination". He needs to be deleted from the Destination since he's not in the Source. 
--- Phyllis has a RecCount of 1 and Table is "Source". She needs to be added to the Destination since she's in the Source. 
---

drop table if exists #updates

select FirstName, LastName, count(*) RecCount, max([Table]) [Table]
    into #updates
    from (
        select 'Source' [Table], [FirstName], [LastName], [Department] from dbo.Source
        except
        select 'Source' [Table], [FirstName], [LastName], [Department] from dbo.Destination

        union all

        select 'Destination' [Table], [FirstName], [LastName], [Department] from dbo.Destination
        except
        select 'Destination' [Table], [FirstName], [LastName], [Department] from dbo.Source
    ) t
    group by FirstName, LastName

select * from #updates

---
--- Insert command
---

insert into dbo.Destination (FirstName, LastName, Department) 
select a.FirstName, a.LastName, a.Department
    from dbo.Source a
    join #updates b
    on a.FirstName=b.FirstName and a.LastName=b.LastName
    where b.RecCount=1 and b.[Table]='Source'

---
--- Updates
---

update dbo.Destination
set Department=b.Department
    from #updates a
    join dbo.Source b
    on a.FirstName=b.FirstName and a.LastName=b.LastName
    join dbo.Destination c
    on a.FirstName=c.FirstName and a.LastName=c.LastName
    where a.RecCount=2

---
--- Deletes
---

delete dbo.Destination 
    from dbo.Destination a
    join #updates b
    on a.FirstName=b.FirstName and a.LastName=b.LastName
    where b.RecCount=1 and b.[Table]='Destination'


---
--- Executing dbo.SyncTables
---

DECLARE @RC int
DECLARE @from_db varchar(500) = 'Utils'
DECLARE @from_schema varchar(500) = 'dbo'
DECLARE @from_table varchar(500) = 'Source'
DECLARE @to_db varchar(500) = 'Utils'
DECLARE @to_schema varchar(500) = 'dbo'
DECLARE @to_table varchar(500) = 'Destination'
DECLARE @msg nvarchar(500)
DECLARE @updates int
DECLARE @inserts int
DECLARE @deletes int

-- TODO: Set parameter values here.

EXECUTE @RC = [dbo].[SyncTables] 
   @from_db
  ,@from_schema
  ,@from_table
  ,@to_db
  ,@to_schema
  ,@to_table
  ,@rc OUTPUT
  ,@msg OUTPUT
  ,@updates OUTPUT
  ,@inserts OUTPUT
  ,@deletes OUTPUT

print @msg
print 'Updates: ' + cast(@updates as varchar)
print 'Inserts: ' + cast(@inserts as varchar)
print 'Deletes: ' + cast(@deletes as varchar)

select * from dbo.Destination