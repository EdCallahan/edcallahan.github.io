use utils
go

IF not exists (select * from sys.schemas where name='tmp_sync')
    EXEC('CREATE SCHEMA tmp_sync');
go

drop procedure if exists [dbo].[SyncTables_NoPK]
go

CREATE PROCEDURE [dbo].[SyncTables_NoPK]

    -- input parameters
     @from_db VARCHAR(500)
    ,@from_schema VARCHAR(500)
    ,@from_table VARCHAR(500)
    ,@to_db VARCHAR(500)
    ,@to_schema VARCHAR(500)
    ,@to_table VARCHAR(500)

    -- output parameters
    ,@rc int OUTPUT
    ,@msg NVARCHAR(500) OUTPUT
    ,@updates INT OUTPUT -- number of rows updated
    ,@inserts INT OUTPUT -- number of rows inserted
    ,@deletes INT OUTPUT -- number of rows deleted

AS
/******************************************************************************
**      Name: SyncTables_NoPK
**      Desc: Sync the data in a table name @table from a database with 
**            up-to-date data (@from_db) to a database that needs to by 
**            updates (@to_db). 
**
**            This procedure is to be used when there is no natural Primary Key
**            in the table being synced. An artificial primary key needs to be
**            created, a single integer field. The view in the Repl database that 
**            retrieves the data must include this field and populate it with NULL.
**            The table in Winona_Repl must have this field and it must be defined
**            as a primary key, without autoincrement. Also, the view in REPL must 
**            carry a distinct clause so each row is unique.
**            
**            This procedure will identify which rows are new and need to be added,
**            or have been removed from OpData and need to be deleted. No updates
**            are done.
**            
**
**      Return values: 0 = success
**                     -1 = No primary keys defined on the destination table.
**                     -2 = Error running EXCEPT statement 
**                     -3 = Error synching
**                     -4 = Source table was empty, will not delete entire destination table
**
**
*******************************************************************************/

BEGIN

    SET NOCOUNT ON

    DECLARE
         @cmd NVARCHAR(MAX)
        ,@cols VARCHAR(MAX)
        ,@pks VARCHAR(MAX)
        ,@maxid int
        ,@error_flag int	
        ,@params nvarchar(4000)
        ,@record_count int 
    
    SET @msg = ''

    --
    -- Cleanup from previous runs in case they failed
    --

    SET @cmd = 'drop table if exists tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table
    EXEC (@cmd)

    --
    -- make sure we're not going to delete too many records
    --

    set @cmd = N'select @c=count(*) from ' + @from_db + '.' + @from_schema + '.' + @from_table
    set @params = N'@c int output'
    exec sp_executesql @cmd, @params, @c=@record_count output

    if @record_count = 0
    begin
        SET @msg = 'No records in source table ' + @from_db + '.' + @from_schema + '.' + @from_table + '. Will not empty destination table'
        SET @rc = -4
        RETURN -4
    end

    BEGIN TRY

		-- get list of columns involved in the tables primary key
            
        set @cmd = 'SELECT @pks = isnull(@pks + '','' + rtrim(K.COLUMN_NAME), rtrim(K.COLUMN_NAME))
        FROM  
            ' + @to_db + '.INFORMATION_SCHEMA.TABLE_CONSTRAINTS T
            INNER JOIN 
            ' + @to_db + '.INFORMATION_SCHEMA.KEY_COLUMN_USAGE K
            ON T.CONSTRAINT_NAME = K.CONSTRAINT_NAME  
        WHERE 
            T.CONSTRAINT_TYPE = ''PRIMARY KEY''  
            AND T.TABLE_NAME = ''' + @to_table + ''' and T.CONSTRAINT_SCHEMA = ''' + @to_schema + ''''


        EXECUTE sp_executesql @cmd, N'@pks varchar(max) output', @pks=@pks OUTPUT

		-- if no primary key is defined, quit
        IF @pks is null
            BEGIN
                SET @msg = 'No primary key defined for ' + @to_db + '.' + @to_schema + '.' + @to_table
                SET @rc = -1
                RETURN -1
            END 

		-- Make sure the primary key consists of only one field
        IF ( SELECT count(*) FROM String_Split(@pks, ',') ) > 1
            BEGIN
                SET @msg = 'primary key defined for ' + @to_db + ' ' + @to_table + ' consists of more than one field'
                RETURN -1
            END 

		-- get a list of the rest of the columns (not in primary key)
        set @cmd = 'select @cols = isnull(@cols + '','' + rtrim(f.COLUMN_NAME), rtrim(f.COLUMN_NAME))
            from ' + @from_db + '.INFORMATION_SCHEMA.COLUMNS f
            join ' + @to_db + '.INFORMATION_SCHEMA.COLUMNS t
                on f.column_name=t.column_name 
                and f.table_schema=''' + @from_schema + ''' and t.table_schema=''' + @to_schema + '''
                and f.table_name=''' + @from_table + ''' and t.table_name=''' + @to_table + '''
            where f.column_name not in ( select value from String_Split(@pks, '','') )'

        EXECUTE sp_executesql @cmd, N'@pks varchar(max), @cols varchar(max) output', @pks=@pks, @cols=@cols OUTPUT
        set @cols = isnull(@cols, '')

        --
        -- get the max value of the Primary Key from that destination table. Store it in
        -- the @maxid variable
        --

        set @cmd = 'set @maxid = (select isnull(max(' + @pks  + '), 0) from ' + @to_db + '.' + @to_schema + '.' + @to_table + ')'
        exec sp_executesql @cmd,  N'@maxid int output', @maxid=@maxid output

        --
        -- renumber the primary key field in the source table
        --

        set @cmd = 'update ' + @from_db + '.' + @from_schema + '.' + @from_table + ' set @id = ' + @pks + ' = @id+1 option (maxdop 1)'
        exec sp_executesql @cmd,  N'@id int', @id=@maxid


		--
		-- We are going to write PK sets of records that need update/insert/deletes to a working table
		-- Make sure the table exists, and that there have been no changes to the PK columns.
		-- Create/Recreate the table if needed
		--
		-- We used to create/destroy these tables on each sproc run, but blocking resulted from locks
		-- on SQL system tables
		--

        --
        -- This is the cool part
        --
        -- We union the two tables. The primary key value in the source table is always greater 
        -- than all the primary key values in the destination table, we just made sure of that above.
        --
        -- Then we group on all values except the primary key. If the count is 2, that means the same
        -- record exists in both WinonaReplImport and Winona_Repl. These records have not been
        -- changed and can be ignored.
        --
        -- if the count is 1, the record exists in either the source table or the destination table. If the
        -- primary key value is less than or equal to the largest primary key value in the destination, 
        -- that means the record and needs to be deleted from the destination table.
        --
        -- if the count is 1 and the primary key value is larger than the largest values in destination,
        -- it is a new record that must be added to the destination
        --
        -- The count can't be greater than 2 because we use a distinct statement in the Repl view.
        -- 

        set @cmd = '
            select max(' + @pks + ') ' + @pks + ',' + @cols + '
            into tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + '
            from (
                select ' + @pks + ',' + @cols + ' from ' + @from_db + '.' + @from_schema + '.' + @from_table + '
                union
                select ' + @pks + ',' + @cols + ' from ' + @to_db + '.' + @to_schema + '.' + @to_table + '
            ) t
            group by ' + @cols + '
            having count(*)=1
        '

        exec (@cmd)

    END TRY
    BEGIN CATCH

        SELECT
            @msg = 'Error running EXCEPT statement on '
            + @from_db + '.' + @from_schema + '.' + @from_table + ' to ' + @to_db + '.' + @to_schema + '.' + @to_table + ': '
            + ERROR_MESSAGE()

        set @rc = -2
        RETURN @rc

    END CATCH

    -- we want all of the insert/update/delete to run before committing
    DECLARE @TranCounter INT = @@TRANCOUNT
    IF @TranCounter = 0
        BEGIN TRANSACTION
    ELSE
        SAVE TRANSACTION trSyncTables


    BEGIN TRY

		--
		-- delete records
		--

        SET @deletes = 0
		-- Need to save the deleted records to make sure they are supposed to be deleted. 

        set @cmd = '
        delete ' + @to_db + '.' + @to_schema + '.' + @to_table + ' 
            from ' + @to_db + '.' + @to_schema + '.' + @to_table + ' a
            join tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + ' b
            on a.' + @pks + ' = b.' + @pks 
        EXEC(@cmd)
        SET @deletes = @@rowcount
        SET @msg = '  Rows deleted:' + CAST(@deletes AS VARCHAR(20)) + ' ' + CHAR(13)

		--
		-- insert records
		--
			
        -- delete the records from TempUpdate table that were just deleted
        SET @cmd = 'delete tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + ' from tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + ' where ' + @pks + ' <= ' + cast(@maxid as varchar)
        exec(@cmd)

        -- reset @maxid now that we've deleted some records from the destination table
        set @cmd = 'set @maxid = (select isnull(max(' + @pks  + '), 0) from ' + @to_db + '.' + @to_schema + '.' + @to_table + ')'
        exec sp_executesql @cmd,  N'@maxid int output', @maxid=@maxid output
        
        -- renumber the primary key in the data to be inserted first, just so we don't run up the size of the primary key
        -- value too high too fast
        SET @cmd = '
        update tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + ' set @id = ' + @pks + ' = @id+1 option (maxdop 1);
        insert into ' + @to_db + '.' + @to_schema + '.' + @to_table + ' (' + @pks + ',' + @cols + ') 
        select ' + @pks + ',' +  @cols + '
            from tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table

        exec sp_executesql @cmd,  N'@id int', @id=@maxid
        SET @inserts = @@rowcount		
        SET @msg = @msg + '  Rows inserted:' + CAST(@inserts AS VARCHAR(20)) + ' ' + CHAR(13)

		--
		-- There are no updates in this methodology
		--
        SET @updates = 0
        SET @msg = @msg + '  Rows updated:' + CAST(@updates AS VARCHAR(20)) + ' ' + CHAR(13)

        IF @TranCounter=0
            COMMIT TRANSACTION

    END TRY
    BEGIN CATCH

        SET  @msg = 'Error synching ' + @from_db + '.' + @from_schema + '.' + @from_table + ' to ' + @to_db + '.' + @to_schema + '.' + @to_table + ': ' + isnull(ERROR_MESSAGE(), '')

        IF @TranCounter = 0  
            ROLLBACK TRANSACTION
        ELSE IF XACT_STATE() <> -1  
            ROLLBACK TRANSACTION trSyncTables  

        set @rc=-3
        return -3

    END CATCH

	--
	-- cleanup and return success
	--

    SET @cmd = 'drop table if exists tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table
    EXEC (@cmd)

    RETURN @rc

END

GO
