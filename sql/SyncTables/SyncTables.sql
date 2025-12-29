use utils
go

drop procedure if exists [dbo].[SyncTables]
go

CREATE PROCEDURE [dbo].[SyncTables]

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
**      Name: SyncTables
**      Desc: Sync the data in a table name @table from a database with 
**            up-to-date data (@from_db) to a database that needs to by 
**            updates (@to_db). 
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
            @cmd nvarchar(4000)
           ,@cols nvarchar(4000)
           ,@pks nvarchar(4000)
           ,@allcols nvarchar(4000)
           ,@on_stmt nvarchar(4000)
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

        -- temp tables that will hold a list of columns involved in the primary keys,
        -- and the columns not involved in primary keys (only columns common to both tables)
        CREATE TABLE #PK ( Column_Name VARCHAR(500) )
        CREATE TABLE #COLS ( Column_Name VARCHAR(500) )

        -- get list of columns involved in the tables primary key
        SET @cmd = '
            INSERT #PK
            SELECT  
                rtrim(K.COLUMN_NAME) column_name
            FROM  
                ' + @to_db + '.INFORMATION_SCHEMA.TABLE_CONSTRAINTS T 
                INNER JOIN 
                ' + @to_db + '.INFORMATION_SCHEMA.KEY_COLUMN_USAGE K 
                ON T.CONSTRAINT_NAME = K.CONSTRAINT_NAME  
            WHERE 
                T.CONSTRAINT_TYPE = ''PRIMARY KEY''  
                AND T.TABLE_NAME = ''' + @to_table + ''' and T.CONSTRAINT_SCHEMA = ''' + @to_schema + ''''


        EXEC (@cmd)

        -- if no primary key is defined, quit
        IF NOT EXISTS ( SELECT * FROM #PK )
            BEGIN
                SET @msg = 'No primary key defined for ' + @to_db + '.' + @to_schema + '.' + @to_table
                SET @rc = -1
                RETURN -1
            END 

        -- get comma delimitted list of PK columns
        SELECT @pks = Column_Name + ISNULL(', ' + @pks, '') FROM #PK

        -- get a list of the rest of the columns (not in primary key)
        SET @cmd = '
            insert #COLS
            select rtrim(f.COLUMN_NAME) column_name
                from ' + @from_db + '.INFORMATION_SCHEMA.COLUMNS f
                join ' + @to_db + '.INFORMATION_SCHEMA.COLUMNS t
                on f.table_name=t.table_name and f.column_name=t.column_name and f.table_schema=t.table_schema
                where f.table_name=''' + @from_table + ''' and f.table_schema=''' + @from_schema + '''
                and f.column_name not in (select column_name from #PK)
                order by f.COLUMN_NAME'

        EXEC (@cmd)
        
        IF @@ROWCOUNT > 0
            -- get comma delimited list of non-PK columns
            SELECT @cols = Column_Name + ISNULL(', ' + @cols, '') FROM #COLS ORDER BY Column_Name DESC
        ELSE
            -- there are no other columns besides the keys.
            SET @cols = ''

        -- get arguments for ON statement following a JOIN based on primary keys
        SELECT @on_stmt = 'a.' + Column_Name + ' = b.' + Column_Name + COALESCE(' and ' + @on_stmt, '') FROM #PK

        -- combine primary key list and non-PK list into one. 
        SET @allcols = 
            CASE 
                WHEN ISNULL(@pks, '') = '' THEN @cols
                WHEN ISNULL(@cols, '') = '' THEN @pks
                ELSE @pks + ', ' + @cols
            END

        --
        -- this is the cool part, using the EXCEPT feature of SQL2005 to generate 
        -- a list of records than need to be modified. A non-temp table (can't use 
        -- a temp table because of dynamic sql constraints) is created in temp_db 
        -- with a field for each column in the primary key, a record type (DBDBDB 
        -- column) and count.
        -- Each record corresponds to a record in the table we are pushing to that 
        -- needs to be updated, inserted or deleted
        --
        -- * record_type = 'to' and count=1: This is a record that only exists in 
        --   the table we are pushing to, delete these records
        --
        -- * record_type = 'from' and count=1: This is a record that does not exist 
        --   in the table we are pushing to, insert these records
        --
        -- * count=2: these records differ between the two tables, run updates for 
        --   these records
        --
        -- Benefits of using the EXCEPT and UNION statements include:
        --
        -- * EXCEPT will handle NULL fields for us
        -- * There is just one SQL command that compares the 2 tables, not for the 
        --   insert, update and delete commands
        --
        SET  @cmd = '
            select min(DBDBDB) DBDBDB, ' + @pks + ', count(*) cnt
            into tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + '
            from (
                    select ''to'' DBDBDB, ' + @allcols + '
                    from ' + @to_db + '.' + @to_schema + '.' + @to_table + ' 
                except 
                    select ''to'' DBDBDB, ' + @allcols + '
                    from ' + @from_db + '.' + @from_schema + '.' + @from_table + '
            union all
                    select ''from'' DBDBDB, ' + @allcols + '
                    from ' + @from_db + '.' + @from_schema + '.' + @from_table + ' 
                except 
                    select ''from'' DBDBDB, ' + @allcols + '
                    from ' + @to_db + '.' + @to_schema + '.' + @to_table + '
            ) a
            group by ' + @pks + ' option (maxdop 1) '

            EXEC (@cmd)

    END TRY
    BEGIN CATCH

        SET @msg = 'Error running EXCEPT statement on ' + @to_db + '.' + @to_schema + '.' + @to_table + ' and ' + @from_db + '.' + @from_schema + '.' + @from_table + ': ' + ERROR_MESSAGE()
        SET @rc=-2
        RETURN -2

    END CATCH

    -- See how many deletes we'd do, quit if too many
    SELECT @cmd = 'select @valOut = count(*) from  tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + ' where cnt=1 and DBDBDB=''to'''
    DECLARE @ParmDef NVARCHAR(MAX) = N'@valOUT INT OUTPUT'
    DECLARE @delcount INT
    EXEC sp_executesql
        @cmd,
        @ParmDef,
        @valOUT = @delcount OUTPUT;

    IF @delcount > 200
    BEGIN

        SET @msg = 'Error updating ' + @to_db + '.' + @to_schema + '.' + @to_table + ', too many records would be deleted (' + cast(@delcount as varchar) + ')'
        SET @rc=-2
        RETURN -2

    END

    -- End Delete Count Check

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

            SELECT
        @cmd = '
            delete ' + @to_db + '.' + @to_schema + '.' + @to_table + ' 
                from ' + @to_db + '.' + @to_schema + '.' + @to_table + ' a
                join tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + ' b
                on ' + @on_stmt + '
                where b.cnt=1 and b.DBDBDB=''to'''

        EXEC(@cmd)
        SET @deletes = @@rowcount
        SET @msg = '  Rows deleted:' + CAST(@deletes AS VARCHAR(20)) + ' ' + CHAR(13)

        --
        -- insert records
        --
        IF @cols <> ''
            SET @cmd = '
                insert into ' + @to_db + '.' + @to_schema + '.' + @to_table + ' (' + @pks + ', ' + @cols + ') 
                select a.' + REPLACE(@pks, ', ', ', a.') + ', a.' + REPLACE(@cols, ', ', ', a.') + '
                    from ' + @from_db + '.' + @from_schema + '.' + @from_table + ' a
                    join tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + ' b
                    on ' + @on_stmt + '
                    where b.cnt=1 and b.DBDBDB=''from'''
        ELSE
            SET @cmd = '
                insert into ' + @to_db + '.' + @to_schema + '.' + @to_table + ' (' + @pks + ') 
                select a.' + REPLACE(@pks, ', ', ', a.') + '
                    from ' + @from_db + '.' + @from_schema + '.' + @from_table + ' a
                    join tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + ' b
                    on ' + @on_stmt + '
                    where b.cnt=1 and b.DBDBDB=''from'''

        EXEC(@cmd)
        SET @inserts = @@rowcount        
        SET @msg = @msg + '  Rows inserted:' + CAST(@inserts AS VARCHAR(20)) + ' ' + CHAR(13)

        --
        -- udpate records, only if there are non-primary key fields to update
        --

        IF EXISTS ( SELECT * FROM #COLS )
        BEGIN

            -- first get the SET portion of the UPDATE command
            SET @cmd = NULL
            SELECT @cmd = Column_Name + ' = b.' + Column_Name + COALESCE(', ' + @cmd, '') FROM #COLS ORDER BY Column_Name DESC

            -- now build the rest of the command
            SET @cmd = '
                update ' + @to_db + '.' + @to_schema + '.' + @to_table + '
                set ' + @cmd + '
                    from tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table + ' a
                    join ' + @from_db + '.' + @from_schema + '.' + @from_table + ' b
                    on ' + @on_stmt + '
                    join ' + @to_db + '.' + @to_schema + '.' + @to_table + ' c
                    on ' + REPLACE(@on_stmt, '= b.', '= c.') + '
                    where a.cnt=2'

            EXEC(@cmd)
            SET @updates = @@rowcount

        END
        ELSE
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
    -- cleanup
    --

    SET @cmd = 'drop table if exists tmp_sync.TempUpdate_' + @to_schema + '_' + @to_table
    EXEC (@cmd)

    set @rc=0
    RETURN 0

END
