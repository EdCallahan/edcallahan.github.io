use Utils
go

drop table if exists dbo.Source
drop table if exists dbo.Destination
go

create table dbo.Source(
     ID int
    ,FirstName varchar(100) NOT NULL
    ,LastName varchar(100) NOT NULL
    ,Department varchar(100)
    ,PRIMARY KEY (FirstName, LastName)
)

create table dbo.Destination(
     ID int not null primary key
    ,FirstName varchar(100) NOT NULL
    ,LastName varchar(100) NOT NULL
    ,Department varchar(100)
)

INSERT INTO dbo.Source (ID, FirstName, LastName, Department) VALUES (NULL, 'Phyllis', 'Vance', 'Sales');
INSERT INTO dbo.Source (ID, FirstName, LastName, Department) VALUES (NULL, 'Stanley', 'Hudson', 'Sales');
INSERT INTO dbo.Source (ID, FirstName, LastName, Department) VALUES (NULL, 'Oscar', 'Martinez', 'Accounting');
INSERT INTO dbo.Source (ID, FirstName, LastName, Department) VALUES (NULL, 'Michael', 'Scott', 'Corporate');

INSERT INTO dbo.Destination (ID, FirstName, LastName, Department) VALUES (1, 'Kevin', 'Malone', 'Accounting');
INSERT INTO dbo.Destination (ID, FirstName, LastName, Department) VALUES (2, 'Stanley', 'Hudson', NULL);
INSERT INTO dbo.Destination (ID, FirstName, LastName, Department) VALUES (3, 'Oscar', 'Martinez', 'Corporate');
INSERT INTO dbo.Destination (ID, FirstName, LastName, Department) VALUES (4, 'Michael', 'Scott', 'Corporate');

select * from dbo.Source
select * from dbo.Destination


---
--- get the max primary key value from the Destination
---

declare @maxid int = (select isnull(max(ID), 0) from dbo.Destination)

---
--- renumber the primary key field in the source table, starting at
--- @maxid+1
---

declare @id int = @maxid
update dbo.Source set @id = ID = @id+1 option (maxdop 1)

select * from dbo.Source

drop table if exists #updates
go

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
order by ID


---
--- Delete command
---

delete dbo.Destination 
    from dbo.Destination a
    join #updates b
    on a.ID=b.ID

---
--- Insert command
---

insert into dbo.Destination (ID, FirstName, LastName, Department) 
select ID, FirstName, LastName, Department
    from #updates
    where ID > (select max(ID) from dbo.Destination)

---
--- Executing dbo.SyncTables
---

DECLARE
     @RC int
    ,@msg nvarchar(500)
    ,@updates int
    ,@inserts int
    ,@deletes int

EXECUTE @RC = [dbo].[SyncTables_NoPK] 
     @from_db = 'Utils'
    ,@from_schema = 'dbo'
    ,@from_table = 'Source'
    ,@to_db = 'Utils'
    ,@to_schema = 'dbo'
    ,@to_table = 'Destination'
    ,@rc = @rc OUTPUT
    ,@msg = @msg OUTPUT
    ,@updates = @updates OUTPUT
    ,@inserts = @inserts OUTPUT
    ,@deletes =@deletes OUTPUT


print @msg
print 'Updates: ' + cast(@updates as varchar)
print 'Inserts: ' + cast(@inserts as varchar)
print 'Deletes: ' + cast(@deletes as varchar)

select * from dbo.Destination
