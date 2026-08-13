#Requires -Version 5.1

<#
.SYNOPSIS
    Диагностика и безопасная отправка алертов Power BI в Mattermost.

.DESCRIPTION
    Режимы выполняются раздельно:
      Test       - локальные тесты без SQL и HTTP;
      Diagnose   - только чтение SQL и вывод потенциальных алертов;
      Initialize - создание/миграция таблицы журнала без отправки;
      Send       - реальная отправка (требует явного режима и webhook).

    Запись со статусом Pending создаётся ДО HTTP-запроса. Поэтому ошибка
    журналирования после успешного HTTP-запроса не приводит к автоматической
    повторной отправке всей очереди.
#>

[CmdletBinding()]
param(
    [ValidateSet("Test", "Diagnose", "Initialize", "Send")]
    [string]$Mode = "Diagnose",

    [string]$SqlServer = "REPORT-S",
    [string]$SqlDatabase = "ra",
    [string]$WebhookUrl = $env:POWERBI_ALERT_MATTERMOST_WEBHOOK,
    [string]$LogFile = "\\Report-s\f$\Project\Logs\DashboardAlerts.log",

    [ValidateRange(0, 10000)]
    [int]$Limit = 0,

    [ValidateRange(1, 86400)]
    [int]$TimeoutThresholdSeconds = 10800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:WriteFileLog = ($Mode -ne "Test")

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )

    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    if ($script:WriteFileLog -and -not [string]::IsNullOrWhiteSpace($LogFile)) {
        try {
            $logDirectory = Split-Path -Path $LogFile -Parent
            if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
                New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Warning "Не удалось записать файловый лог '$LogFile': $($_.Exception.Message)"
        }
    }
    Write-Host $entry
}

function Get-RowValue {
    param(
        [Parameter(Mandatory = $true)][System.Data.DataRow]$Row,
        [Parameter(Mandatory = $true)][string]$ColumnName,
        [object]$Default = $null
    )

    if (-not $Row.Table.Columns.Contains($ColumnName) -or $Row.IsNull($ColumnName)) {
        return $Default
    }
    return $Row[$ColumnName]
}

function Get-AlertTypes {
    param(
        [Parameter(Mandatory = $true)][int]$Status,
        [Parameter(Mandatory = $true)][int]$DurationSeconds,
        [Parameter(Mandatory = $true)][int]$ThresholdSeconds
    )

    $types = [System.Collections.Generic.List[string]]::new()
    if ($Status -eq 2) {
        $types.Add("Error")
    }
    if ($DurationSeconds -gt $ThresholdSeconds) {
        $types.Add("Timeout")
    }
    return $types.ToArray()
}

function New-SqlConnection {
    $connectionString = "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=SSPI;Application Name=PowerBIAlertDispatcher;"
    return [System.Data.SqlClient.SqlConnection]::new($connectionString)
}

function Add-SqlParameter {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlCommand]$Command,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][System.Data.SqlDbType]$Type,
        [Parameter(Mandatory = $true)][object]$Value,
        [int]$Size = 0
    )

    $parameter = if ($Size -gt 0) {
        $Command.Parameters.Add($Name, $Type, $Size)
    }
    else {
        $Command.Parameters.Add($Name, $Type)
    }
    $parameter.Value = $Value
    return $parameter
}

function Get-SourceRows {
    param([Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection)

    $query = @"
SELECT
    [ReportName],
    [ReportPath],
    [SubscriptionID],
    [StartTime],
    [EndTime],
    [DurationSeconds],
    [DurationMinutes],
    [status],
    [Message],
    [Details],
    [InactiveFlags],
    [LastStatus],
    [EventType],
    [LastRunTime]
FROM OPENQUERY([REPORT-R], '
    SELECT
        [name] AS ReportName,
        [path] AS ReportPath,
        [SubscriptionID],
        [StartTime],
        [EndTime],
        [Длительность обновления, сек.] AS DurationSeconds,
        [Длительность обновления, мин.] AS DurationMinutes,
        [status],
        [Message],
        [Details],
        [InactiveFlags],
        [LastStatus],
        [EventType],
        [LastRunTime]
    FROM [ra].[dbo].[BI_Report_Refresh_Error]
    WHERE [path] LIKE ''/Product%''
') AS SourceRows
ORDER BY [StartTime], [SubscriptionID];
"@

    $command = [System.Data.SqlClient.SqlCommand]::new($query, $Connection)
    $command.CommandTimeout = 120
    $adapter = [System.Data.SqlClient.SqlDataAdapter]::new($command)
    $table = [System.Data.DataTable]::new()
    try {
        [void]$adapter.Fill($table)
        return $table
    }
    finally {
        $adapter.Dispose()
        $command.Dispose()
    }
}

function Initialize-HistoryTable {
    param([Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection)

    $query = @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'pbix')
    EXEC(N'CREATE SCHEMA [pbix]');

IF OBJECT_ID(N'[pbix].[AlertHistory]', N'U') IS NULL
BEGIN
    CREATE TABLE [pbix].[AlertHistory] (
        [Id] INT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_AlertHistory] PRIMARY KEY,
        [SubscriptionID] UNIQUEIDENTIFIER NOT NULL,
        [StartTime] DATETIME2(3) NOT NULL,
        [EndTime] DATETIME2(3) NOT NULL,
        [DurationSeconds] INT NOT NULL,
        [AlertType] VARCHAR(20) NOT NULL,
        [DeliveryStatus] VARCHAR(20) NOT NULL
            CONSTRAINT [DF_AlertHistory_DeliveryStatus] DEFAULT ('Pending'),
        [ReportName] NVARCHAR(512) NULL,
        [CreatedDate] DATETIME2(0) NOT NULL
            CONSTRAINT [DF_AlertHistory_CreatedDate] DEFAULT (SYSUTCDATETIME()),
        [LastAttemptDate] DATETIME2(0) NOT NULL
            CONSTRAINT [DF_AlertHistory_LastAttemptDate] DEFAULT (SYSUTCDATETIME()),
        [SentDate] DATETIME2(0) NULL,
        [LastError] NVARCHAR(4000) NULL,
        CONSTRAINT [CK_AlertHistory_DeliveryStatus]
            CHECK ([DeliveryStatus] IN ('Pending', 'Sent', 'Failed', 'Unknown'))
    );
END
ELSE
BEGIN
    IF EXISTS (
        SELECT 1 FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'[pbix].[AlertHistory]')
          AND name = N'UX_AlertHistory_AlertKey'
    )
        DROP INDEX [UX_AlertHistory_AlertKey] ON [pbix].[AlertHistory];

    IF EXISTS (
        SELECT 1 FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'[pbix].[AlertHistory]')
          AND name = N'IX_AlertHistory_SubscriptionID_StartTime_AlertType'
    )
        DROP INDEX [IX_AlertHistory_SubscriptionID_StartTime_AlertType] ON [pbix].[AlertHistory];

    IF EXISTS (
        SELECT 1 FROM sys.check_constraints
        WHERE parent_object_id = OBJECT_ID(N'[pbix].[AlertHistory]')
          AND name = N'CK_AlertHistory_DeliveryStatus'
    )
        ALTER TABLE [pbix].[AlertHistory] DROP CONSTRAINT [CK_AlertHistory_DeliveryStatus];

    IF NOT EXISTS (
        SELECT 1
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        WHERE c.object_id = OBJECT_ID(N'[pbix].[AlertHistory]')
          AND c.name = N'Id'
          AND t.name = N'int'
          AND c.is_identity = 1
    )
        THROW 51006, 'AlertHistory.Id должна существовать и иметь тип INT IDENTITY.', 1;
    IF COL_LENGTH(N'pbix.AlertHistory', N'SubscriptionID') IS NULL
        THROW 51001, 'В AlertHistory отсутствует обязательная колонка SubscriptionID.', 1;
    IF COL_LENGTH(N'pbix.AlertHistory', N'StartTime') IS NULL
        THROW 51002, 'В AlertHistory отсутствует обязательная колонка StartTime.', 1;
    IF COL_LENGTH(N'pbix.AlertHistory', N'EndTime') IS NULL
        THROW 51003, 'В AlertHistory отсутствует обязательная колонка EndTime.', 1;
    IF COL_LENGTH(N'pbix.AlertHistory', N'DurationSeconds') IS NULL
        THROW 51004, 'В AlertHistory отсутствует обязательная колонка DurationSeconds.', 1;
    IF COL_LENGTH(N'pbix.AlertHistory', N'AlertType') IS NULL
        THROW 51005, 'В AlertHistory отсутствует обязательная колонка AlertType.', 1;

    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [SubscriptionID] UNIQUEIDENTIFIER NOT NULL;
    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [StartTime] DATETIME2(3) NOT NULL;
    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [EndTime] DATETIME2(3) NOT NULL;
    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [DurationSeconds] INT NOT NULL;
    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [AlertType] VARCHAR(20) NOT NULL;

    IF COL_LENGTH(N'pbix.AlertHistory', N'DeliveryStatus') IS NULL
        ALTER TABLE [pbix].[AlertHistory] ADD [DeliveryStatus] VARCHAR(20) NOT NULL
            CONSTRAINT [DF_AlertHistory_DeliveryStatus] DEFAULT ('Sent') WITH VALUES;
    IF COL_LENGTH(N'pbix.AlertHistory', N'ReportName') IS NULL
        ALTER TABLE [pbix].[AlertHistory] ADD [ReportName] NVARCHAR(512) NULL;
    IF COL_LENGTH(N'pbix.AlertHistory', N'CreatedDate') IS NULL
        ALTER TABLE [pbix].[AlertHistory] ADD [CreatedDate] DATETIME2(0) NOT NULL
            CONSTRAINT [DF_AlertHistory_CreatedDate] DEFAULT (SYSUTCDATETIME()) WITH VALUES;
    IF COL_LENGTH(N'pbix.AlertHistory', N'LastAttemptDate') IS NULL
        ALTER TABLE [pbix].[AlertHistory] ADD [LastAttemptDate] DATETIME2(0) NOT NULL
            CONSTRAINT [DF_AlertHistory_LastAttemptDate] DEFAULT (SYSUTCDATETIME()) WITH VALUES;
    IF COL_LENGTH(N'pbix.AlertHistory', N'SentDate') IS NULL
        ALTER TABLE [pbix].[AlertHistory] ADD [SentDate] DATETIME2(0) NULL;
    IF COL_LENGTH(N'pbix.AlertHistory', N'LastError') IS NULL
        ALTER TABLE [pbix].[AlertHistory] ADD [LastError] NVARCHAR(4000) NULL;

    UPDATE [pbix].[AlertHistory]
    SET [DeliveryStatus] = 'Unknown'
    WHERE [DeliveryStatus] IS NULL
       OR [DeliveryStatus] NOT IN ('Pending', 'Sent', 'Failed', 'Unknown');

    UPDATE [pbix].[AlertHistory]
    SET [CreatedDate] = COALESCE([SentDate], SYSUTCDATETIME())
    WHERE [CreatedDate] IS NULL;

    UPDATE [pbix].[AlertHistory]
    SET [LastAttemptDate] = [CreatedDate]
    WHERE [LastAttemptDate] IS NULL;

    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [DeliveryStatus] VARCHAR(20) NOT NULL;
    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [ReportName] NVARCHAR(512) NULL;
    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [CreatedDate] DATETIME2(0) NOT NULL;
    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [LastAttemptDate] DATETIME2(0) NOT NULL;
    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [SentDate] DATETIME2(0) NULL;
    ALTER TABLE [pbix].[AlertHistory] ALTER COLUMN [LastError] NVARCHAR(4000) NULL;

    ALTER TABLE [pbix].[AlertHistory] WITH CHECK
        ADD CONSTRAINT [CK_AlertHistory_DeliveryStatus]
        CHECK ([DeliveryStatus] IN ('Pending', 'Sent', 'Failed', 'Unknown'));
END;

IF EXISTS (
    SELECT 1
    FROM [pbix].[AlertHistory]
    GROUP BY [SubscriptionID], [StartTime], [AlertType]
    HAVING COUNT_BIG(*) > 1
)
    THROW 51000, 'В AlertHistory есть дубли. Удалите их после проверки перед созданием уникального индекса.', 1;

IF EXISTS (
    SELECT 1
    FROM sys.indexes AS i
    WHERE i.object_id = OBJECT_ID(N'[pbix].[AlertHistory]')
      AND i.name = N'UX_AlertHistory_AlertKey'
      AND (
          i.is_unique = 0
          OR 3 <> (
              SELECT COUNT(*)
              FROM sys.index_columns AS ic
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.key_ordinal > 0
          )
          OR NOT EXISTS (
              SELECT 1
              FROM sys.index_columns AS ic
              JOIN sys.columns AS c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.key_ordinal = 1
                AND c.name = N'SubscriptionID'
          )
          OR NOT EXISTS (
              SELECT 1
              FROM sys.index_columns AS ic
              JOIN sys.columns AS c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.key_ordinal = 2
                AND c.name = N'StartTime'
          )
          OR NOT EXISTS (
              SELECT 1
              FROM sys.index_columns AS ic
              JOIN sys.columns AS c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.key_ordinal = 3
                AND c.name = N'AlertType'
          )
      )
)
    DROP INDEX [UX_AlertHistory_AlertKey] ON [pbix].[AlertHistory];

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[pbix].[AlertHistory]')
      AND name = N'UX_AlertHistory_AlertKey'
)
    CREATE UNIQUE INDEX [UX_AlertHistory_AlertKey]
        ON [pbix].[AlertHistory] ([SubscriptionID], [StartTime], [AlertType]);

COMMIT TRANSACTION;
"@

    $command = [System.Data.SqlClient.SqlCommand]::new($query, $Connection)
    $command.CommandTimeout = 120
    try {
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
    }
}

function Test-HistoryTable {
    param([Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection)

    $query = @"
SELECT
    CASE WHEN OBJECT_ID(N'[pbix].[AlertHistory]', N'U') IS NULL THEN 0 ELSE 1 END AS TableExists,
    CASE WHEN 3 = (
        SELECT COUNT(*)
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        WHERE c.object_id = OBJECT_ID(N'[pbix].[AlertHistory]')
          AND (
              (c.name = N'SubscriptionID' AND t.name = N'uniqueidentifier')
              OR (c.name = N'StartTime' AND t.name IN (N'datetime', N'datetime2'))
              OR (c.name = N'AlertType' AND t.name IN (N'varchar', N'nvarchar'))
          )
    ) THEN 1 ELSE 0 END AS HasKeyColumns,
    CASE WHEN 12 = (
        SELECT COUNT(*)
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        WHERE c.object_id = OBJECT_ID(N'[pbix].[AlertHistory]')
          AND (
              (c.name = N'SubscriptionID' AND t.name = N'uniqueidentifier' AND c.is_nullable = 0)
              OR (c.name = N'StartTime' AND t.name = N'datetime2' AND c.scale = 3 AND c.is_nullable = 0)
              OR (c.name = N'EndTime' AND t.name = N'datetime2' AND c.scale = 3 AND c.is_nullable = 0)
              OR (c.name = N'DurationSeconds' AND t.name = N'int' AND c.is_nullable = 0)
              OR (c.name = N'AlertType' AND t.name = N'varchar' AND c.max_length >= 20 AND c.is_nullable = 0)
              OR (c.name = N'DeliveryStatus' AND t.name = N'varchar' AND c.max_length >= 20 AND c.is_nullable = 0)
              OR (c.name = N'ReportName' AND t.name = N'nvarchar' AND c.max_length >= 1024 AND c.is_nullable = 1)
              OR (c.name = N'CreatedDate' AND t.name = N'datetime2' AND c.is_nullable = 0)
              OR (c.name = N'LastAttemptDate' AND t.name = N'datetime2' AND c.is_nullable = 0)
              OR (c.name = N'SentDate' AND t.name = N'datetime2' AND c.is_nullable = 1)
              OR (c.name = N'LastError' AND t.name = N'nvarchar' AND c.max_length >= 8000 AND c.is_nullable = 1)
              OR (c.name = N'Id' AND t.name = N'int' AND c.is_identity = 1 AND c.is_nullable = 0)
          )
    )
    AND EXISTS (
        SELECT 1
        FROM sys.check_constraints
        WHERE parent_object_id = OBJECT_ID(N'[pbix].[AlertHistory]')
          AND name = N'CK_AlertHistory_DeliveryStatus'
          AND is_disabled = 0
          AND is_not_trusted = 0
          AND definition LIKE N'%Pending%'
          AND definition LIKE N'%Sent%'
          AND definition LIKE N'%Failed%'
          AND definition LIKE N'%Unknown%'
    ) THEN 1 ELSE 0 END AS SchemaReady,
    CASE WHEN EXISTS (
        SELECT 1
        FROM sys.indexes AS i
        WHERE i.object_id = OBJECT_ID(N'[pbix].[AlertHistory]')
          AND i.name = N'UX_AlertHistory_AlertKey'
          AND i.is_unique = 1
          AND i.is_disabled = 0
          AND i.has_filter = 0
          AND 3 = (
              SELECT COUNT(*) FROM sys.index_columns AS ic
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.key_ordinal > 0
          )
          AND N'SubscriptionID' = (
              SELECT c.name
              FROM sys.index_columns AS ic
              JOIN sys.columns AS c
                ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal = 1
          )
          AND N'StartTime' = (
              SELECT c.name
              FROM sys.index_columns AS ic
              JOIN sys.columns AS c
                ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal = 2
          )
          AND N'AlertType' = (
              SELECT c.name
              FROM sys.index_columns AS ic
              JOIN sys.columns AS c
                ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal = 3
          )
    ) THEN 1 ELSE 0 END AS UniqueIndexExists;
"@
    $command = [System.Data.SqlClient.SqlCommand]::new($query, $Connection)
    try {
        $reader = $command.ExecuteReader()
        try {
            [void]$reader.Read()
            return [pscustomobject]@{
                TableExists       = ([int]$reader["TableExists"] -eq 1)
                HasKeyColumns     = ([int]$reader["HasKeyColumns"] -eq 1)
                SchemaReady       = ([int]$reader["SchemaReady"] -eq 1)
                UniqueIndexExists = ([int]$reader["UniqueIndexExists"] -eq 1)
            }
        }
        finally {
            $reader.Close()
        }
    }
    finally {
        $command.Dispose()
    }
}

function Get-HistoryDiagnostics {
    param([Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection)

    $query = @"
IF OBJECT_ID(N'[pbix].[AlertHistory]', N'U') IS NULL
BEGIN
    SELECT
        CAST(0 AS BIGINT) AS TotalRows,
        CAST(0 AS BIGINT) AS DuplicateKeys,
        CAST(0 AS BIGINT) AS PendingRows,
        CAST(0 AS BIGINT) AS FailedRows,
        CAST(0 AS BIGINT) AS UnknownRows;
END
ELSE
BEGIN
    DECLARE @HasStatus bit =
        CASE WHEN COL_LENGTH(N'pbix.AlertHistory', N'DeliveryStatus') IS NULL THEN 0 ELSE 1 END;

    DECLARE @Sql nvarchar(max) = N'
        SELECT
            COUNT_BIG(*) AS TotalRows,
            (
                SELECT COUNT_BIG(*)
                FROM (
                    SELECT 1 AS DuplicateKey
                    FROM [pbix].[AlertHistory]
                    GROUP BY [SubscriptionID], [StartTime], [AlertType]
                    HAVING COUNT_BIG(*) > 1
                ) AS D
            ) AS DuplicateKeys,
            ' + CASE WHEN @HasStatus = 1
                THEN N'SUM(CASE WHEN [DeliveryStatus] = ''Pending'' THEN 1 ELSE 0 END)'
                ELSE N'CAST(0 AS BIGINT)' END + N' AS PendingRows,
            ' + CASE WHEN @HasStatus = 1
                THEN N'SUM(CASE WHEN [DeliveryStatus] = ''Failed'' THEN 1 ELSE 0 END)'
                ELSE N'CAST(0 AS BIGINT)' END + N' AS FailedRows
            ,
            ' + CASE WHEN @HasStatus = 1
                THEN N'SUM(CASE WHEN [DeliveryStatus] = ''Unknown'' THEN 1 ELSE 0 END)'
                ELSE N'CAST(0 AS BIGINT)' END + N' AS UnknownRows
        FROM [pbix].[AlertHistory];';
    EXEC sys.sp_executesql @Sql;
END;
"@

    $command = [System.Data.SqlClient.SqlCommand]::new($query, $Connection)
    try {
        $reader = $command.ExecuteReader()
        try {
            [void]$reader.Read()
            return [pscustomobject]@{
                TotalRows     = [long]$reader["TotalRows"]
                DuplicateKeys = [long]$reader["DuplicateKeys"]
                PendingRows   = if ($reader.IsDBNull(2)) { 0L } else { [long]$reader["PendingRows"] }
                FailedRows    = if ($reader.IsDBNull(3)) { 0L } else { [long]$reader["FailedRows"] }
                UnknownRows   = if ($reader.IsDBNull(4)) { 0L } else { [long]$reader["UnknownRows"] }
            }
        }
        finally {
            $reader.Close()
        }
    }
    finally {
        $command.Dispose()
    }
}

function Lock-Dispatcher {
    param([Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection)

    $query = @"
DECLARE @Result int;
EXEC @Result = sys.sp_getapplock
    @Resource = N'pbix.PowerBIAlertDispatcher',
    @LockMode = N'Exclusive',
    @LockOwner = N'Session',
    @LockTimeout = 0;
SELECT @Result;
"@
    $command = [System.Data.SqlClient.SqlCommand]::new($query, $Connection)
    try {
        $result = [int]$command.ExecuteScalar()
        if ($result -lt 0) {
            throw "Другой экземпляр отправщика уже выполняется (sp_getapplock: $result)."
        }
    }
    finally {
        $command.Dispose()
    }
}

function Request-Delivery {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory = $true)][guid]$SubscriptionID,
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][datetime]$EndTime,
        [Parameter(Mandatory = $true)][int]$DurationSeconds,
        [Parameter(Mandatory = $true)][string]$AlertType,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ReportName
    )

    $query = @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;

DECLARE @ExistingStatus varchar(20);
SELECT @ExistingStatus = [DeliveryStatus]
FROM [pbix].[AlertHistory] WITH (UPDLOCK, HOLDLOCK)
WHERE [SubscriptionID] = @SubscriptionID
  AND [StartTime] = @StartTime
  AND [AlertType] = @AlertType;

IF @ExistingStatus IS NULL
BEGIN
    INSERT INTO [pbix].[AlertHistory] (
        [SubscriptionID], [StartTime], [EndTime], [DurationSeconds], [AlertType],
        [DeliveryStatus], [ReportName], [CreatedDate], [LastAttemptDate], [SentDate], [LastError]
    )
    VALUES (
        @SubscriptionID, @StartTime, @EndTime, @DurationSeconds, @AlertType,
        'Pending', @ReportName, SYSUTCDATETIME(), SYSUTCDATETIME(), NULL, NULL
    );
    SELECT CAST(1 AS int);
END
ELSE
    SELECT CAST(0 AS int);

COMMIT TRANSACTION;
"@

    $command = [System.Data.SqlClient.SqlCommand]::new($query, $Connection)
    try {
        [void](Add-SqlParameter $command "@SubscriptionID" ([System.Data.SqlDbType]::UniqueIdentifier) $SubscriptionID)
        [void](Add-SqlParameter $command "@StartTime" ([System.Data.SqlDbType]::DateTime2) $StartTime)
        [void](Add-SqlParameter $command "@EndTime" ([System.Data.SqlDbType]::DateTime2) $EndTime)
        [void](Add-SqlParameter $command "@DurationSeconds" ([System.Data.SqlDbType]::Int) $DurationSeconds)
        [void](Add-SqlParameter $command "@AlertType" ([System.Data.SqlDbType]::VarChar) $AlertType 20)
        [void](Add-SqlParameter $command "@ReportName" ([System.Data.SqlDbType]::NVarChar) $ReportName 512)
        return ([int]$command.ExecuteScalar() -eq 1)
    }
    finally {
        $command.Dispose()
    }
}

function Set-DeliveryResult {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory = $true)][guid]$SubscriptionID,
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][string]$AlertType,
        [Parameter(Mandatory = $true)][bool]$Succeeded,
        [string]$ErrorMessage
    )

    $query = @"
UPDATE [pbix].[AlertHistory]
SET [DeliveryStatus] = @DeliveryStatus,
    [SentDate] = CASE WHEN @DeliveryStatus = 'Sent' THEN SYSUTCDATETIME() ELSE NULL END,
    [LastAttemptDate] = SYSUTCDATETIME(),
    [LastError] = @LastError
WHERE [SubscriptionID] = @SubscriptionID
  AND [StartTime] = @StartTime
  AND [AlertType] = @AlertType
  AND [DeliveryStatus] = 'Pending';

SELECT @@ROWCOUNT;
"@
    $command = [System.Data.SqlClient.SqlCommand]::new($query, $Connection)
    try {
        [void](Add-SqlParameter $command "@DeliveryStatus" ([System.Data.SqlDbType]::VarChar) $(if ($Succeeded) { "Sent" } else { "Unknown" }) 20)
        [void](Add-SqlParameter $command "@LastError" ([System.Data.SqlDbType]::NVarChar) $(if ($ErrorMessage) { $ErrorMessage } else { [DBNull]::Value }) 4000)
        [void](Add-SqlParameter $command "@SubscriptionID" ([System.Data.SqlDbType]::UniqueIdentifier) $SubscriptionID)
        [void](Add-SqlParameter $command "@StartTime" ([System.Data.SqlDbType]::DateTime2) $StartTime)
        [void](Add-SqlParameter $command "@AlertType" ([System.Data.SqlDbType]::VarChar) $AlertType 20)
        if ([int]$command.ExecuteScalar() -ne 1) {
            throw "Не удалось изменить статус Pending для $SubscriptionID/$StartTime/$AlertType."
        }
    }
    finally {
        $command.Dispose()
    }
}

function Format-AlertText {
    param(
        [Parameter(Mandatory = $true)][string]$AlertType,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ReportName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ReportPath,
        [Parameter(Mandatory = $true)][guid]$SubscriptionID,
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][datetime]$EndTime,
        [Parameter(Mandatory = $true)][int]$DurationSeconds,
        [Parameter(Mandatory = $true)][int]$DurationMinutes,
        [Parameter(Mandatory = $true)][int]$Status,
        [string]$Message,
        [string]$Details
    )

    $title = if ($AlertType -eq "Error") {
        "Ошибка обновления дашборда!"
    }
    else {
        "Превышение времени обновления дашборда!"
    }
    $durationComment = if ($AlertType -eq "Timeout") {
        " — превышает $([math]::Round($TimeoutThresholdSeconds / 3600, 2)) ч."
    }
    else {
        ""
    }

    return @"
**$title**

- **Название:** $ReportName
- **Путь:** $ReportPath
- **SubscriptionID:** $SubscriptionID
- **Время начала:** $($StartTime.ToString("yyyy-MM-dd HH:mm:ss"))
- **Время окончания:** $($EndTime.ToString("yyyy-MM-dd HH:mm:ss"))
- **Длительность:** $DurationMinutes мин. ($DurationSeconds сек.)$durationComment
- **Статус:** $Status
- **Сообщение:** $Message
- **Детали:** $Details
"@
}

function Send-MattermostMessage {
    param([Parameter(Mandatory = $true)][string]$Text)

    $body = @{ text = $Text } | ConvertTo-Json -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $response = Invoke-WebRequest `
        -Uri $WebhookUrl `
        -Method Post `
        -ContentType "application/json; charset=utf-8" `
        -Body $bodyBytes `
        -TimeoutSec 30 `
        -UseBasicParsing

    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw "Mattermost вернул HTTP $($response.StatusCode)."
    }
    return [int]$response.StatusCode
}

function ConvertTo-AlertCandidate {
    param([Parameter(Mandatory = $true)][System.Data.DataRow]$Row)

    $subscriptionValue = Get-RowValue $Row "SubscriptionID"
    $startValue = Get-RowValue $Row "StartTime"
    if ($null -eq $subscriptionValue -or $null -eq $startValue) {
        throw "В исходной записи отсутствует SubscriptionID или StartTime."
    }

    $subscriptionID = [guid]$subscriptionValue
    if ($subscriptionID -eq [guid]::Empty) {
        throw "В исходной записи указан пустой SubscriptionID."
    }

    $startTime = [datetime]$startValue
    $endTime = [datetime](Get-RowValue $Row "EndTime" $startTime)
    $durationSeconds = [int](Get-RowValue $Row "DurationSeconds" 0)

    return [pscustomobject]@{
        SubscriptionID = $subscriptionID
        StartTime       = $startTime
        EndTime         = $endTime
        DurationSeconds = $durationSeconds
        DurationMinutes = [int](Get-RowValue $Row "DurationMinutes" ([math]::Floor($durationSeconds / 60)))
        ReportName      = [string](Get-RowValue $Row "ReportName" "")
        ReportPath      = [string](Get-RowValue $Row "ReportPath" "")
        Status          = [int](Get-RowValue $Row "status" 0)
        Message         = [string](Get-RowValue $Row "Message" "")
        Details         = [string](Get-RowValue $Row "Details" "")
    }
}

function Invoke-SelfTests {
    $failures = [System.Collections.Generic.List[string]]::new()

    function Assert-Equal {
        param([string]$Name, [object]$Expected, [object]$Actual)
        if ("$Expected" -ne "$Actual") {
            $failures.Add("$Name`: ожидалось '$Expected', получено '$Actual'")
        }
        else {
            Write-Log "PASS: $Name"
        }
    }

    Assert-Equal "Обычное обновление не создаёт алерт" 0 @(Get-AlertTypes 0 60 $TimeoutThresholdSeconds).Count
    Assert-Equal "Ошибка создаёт Error" "Error" ((Get-AlertTypes 2 60 $TimeoutThresholdSeconds) -join ",")
    Assert-Equal "Долгое обновление создаёт Timeout" "Timeout" ((Get-AlertTypes 0 ($TimeoutThresholdSeconds + 1) $TimeoutThresholdSeconds) -join ",")
    Assert-Equal "Ошибка и таймаут создают два независимых алерта" "Error,Timeout" ((Get-AlertTypes 2 ($TimeoutThresholdSeconds + 1) $TimeoutThresholdSeconds) -join ",")
    Assert-Equal "Граница таймаута не превышена" 0 @(Get-AlertTypes 0 $TimeoutThresholdSeconds $TimeoutThresholdSeconds).Count

    $unicodeBody = @{ text = "Ошибка обновления" } | ConvertTo-Json -Compress
    $roundTrip = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::UTF8.GetBytes($unicodeBody)) | ConvertFrom-Json
    Assert-Equal "UTF-8 сохраняет кириллицу" "Ошибка обновления" $roundTrip.text

    $scriptText = [System.IO.File]::ReadAllText($PSCommandPath)
    Assert-Equal "Webhook отсутствует в исходном коде" $false ([regex]::IsMatch($scriptText, "https://[^`"']+/hooks/"))
    Assert-Equal "Безопасный режим запуска по умолчанию" $true ([regex]::IsMatch($scriptText, '\[string\]\$Mode = "Diagnose"'))
    Assert-Equal "Лимит не применяется до дедупликации" $false ([regex]::IsMatch($scriptText, 'SELECT\s+\$topClause'))
    $unsafeRetryParameter = "Retry" + "Failed"
    Assert-Equal "Неопределённая доставка не повторяется автоматически" $false ([regex]::IsMatch($scriptText, $unsafeRetryParameter))
    Assert-Equal "Неопределённая доставка имеет отдельный статус" $true ([regex]::IsMatch($scriptText, "DeliveryStatus.+Unknown", [System.Text.RegularExpressions.RegexOptions]::Singleline))

    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) {
            Write-Log "FAIL: $failure" "ERROR"
        }
        throw "Провалено тестов: $($failures.Count)."
    }
    Write-Log "Все локальные тесты пройдены: 11."
}

function Invoke-Diagnostics {
    param([Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection)

    $schema = Test-HistoryTable $Connection
    $history = [pscustomobject]@{
        TotalRows     = 0L
        DuplicateKeys = 0L
        PendingRows   = 0L
        FailedRows    = 0L
        UnknownRows   = 0L
    }
    if ($schema.TableExists -and $schema.HasKeyColumns) {
        $history = Get-HistoryDiagnostics $Connection
    }
    $rows = Get-SourceRows $Connection
    $candidateCount = 0
    $invalidCount = 0

    foreach ($row in $rows.Rows) {
        try {
            $candidate = ConvertTo-AlertCandidate $row
            $candidateCount += @(Get-AlertTypes $candidate.Status $candidate.DurationSeconds $TimeoutThresholdSeconds).Count
        }
        catch {
            $invalidCount++
            Write-Log "Некорректная исходная запись: $($_.Exception.Message)" "WARN"
        }
    }

    Write-Log "Диагностика завершена без изменений в SQL и без HTTP-запросов. Файловый диагностический лог обновлён."
    Write-Log "Источник: строк=$($rows.Rows.Count), потенциальных алертов=$candidateCount, некорректных строк=$invalidCount."
    Write-Log "AlertHistory: существует=$($schema.TableExists), схема готова=$($schema.SchemaReady), уникальный индекс корректен=$($schema.UniqueIndexExists)."
    Write-Log "AlertHistory: строк=$($history.TotalRows), ключей-дублей=$($history.DuplicateKeys), Pending=$($history.PendingRows), Failed=$($history.FailedRows), Unknown=$($history.UnknownRows)."

    if (-not $schema.SchemaReady -or -not $schema.UniqueIndexExists) {
        Write-Log "Перед Send выполните режим Initialize." "WARN"
    }
    if ($history.DuplicateKeys -gt 0) {
        Write-Log "Initialize остановится до ручной проверки и удаления дублей." "WARN"
    }
}

function Invoke-Delivery {
    param([Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection)

    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
        throw "Webhook не задан. Установите POWERBI_ALERT_MATTERMOST_WEBHOOK только перед режимом Send."
    }

    $schema = Test-HistoryTable $Connection
    if (-not $schema.SchemaReady -or -not $schema.UniqueIndexExists) {
        throw "Таблица журнала не инициализирована. Сначала выполните -Mode Initialize."
    }

    Lock-Dispatcher $Connection
    $rows = Get-SourceRows $Connection
    $sentCount = 0
    $skippedCount = 0
    $failedCount = 0
    $claimedCount = 0

    :SourceRow foreach ($row in $rows.Rows) {
        try {
            $candidate = ConvertTo-AlertCandidate $row
        }
        catch {
            $failedCount++
            Write-Log "Исходная запись пропущена: $($_.Exception.Message)" "ERROR"
            continue
        }

        $alertTypes = Get-AlertTypes $candidate.Status $candidate.DurationSeconds $TimeoutThresholdSeconds
        foreach ($alertType in $alertTypes) {
            try {
                $text = Format-AlertText `
                    -AlertType $alertType `
                    -ReportName $candidate.ReportName `
                    -ReportPath $candidate.ReportPath `
                    -SubscriptionID $candidate.SubscriptionID `
                    -StartTime $candidate.StartTime `
                    -EndTime $candidate.EndTime `
                    -DurationSeconds $candidate.DurationSeconds `
                    -DurationMinutes $candidate.DurationMinutes `
                    -Status $candidate.Status `
                    -Message $candidate.Message `
                    -Details $candidate.Details
            }
            catch {
                $failedCount++
                Write-Log "Не удалось сформировать $alertType для '$($candidate.ReportName)': $($_.Exception.Message)" "ERROR"
                continue
            }

            $claimed = Request-Delivery `
                -Connection $Connection `
                -SubscriptionID $candidate.SubscriptionID `
                -StartTime $candidate.StartTime `
                -EndTime $candidate.EndTime `
                -DurationSeconds $candidate.DurationSeconds `
                -AlertType $alertType `
                -ReportName $candidate.ReportName

            if (-not $claimed) {
                $skippedCount++
                Write-Log "Алерт $alertType для '$($candidate.ReportName)' уже зарегистрирован; пропуск." "DEBUG"
                continue
            }

            $claimedCount++

            try {
                $statusCode = Send-MattermostMessage $text
                $sentCount++
                try {
                    Set-DeliveryResult $Connection $candidate.SubscriptionID $candidate.StartTime $alertType $true
                    Write-Log "Алерт $alertType для '$($candidate.ReportName)' отправлен (HTTP $statusCode) и записан в журнал."
                }
                catch {
                    Write-Log "Сообщение отправлено, но статус журнала остался Pending: $($_.Exception.Message). Повтор автоматически заблокирован." "ERROR"
                }
            }
            catch {
                $failedCount++
                $sendError = $_.Exception.Message
                try {
                    Set-DeliveryResult $Connection $candidate.SubscriptionID $candidate.StartTime $alertType $false $sendError
                }
                catch {
                    Write-Log "Не удалось записать ошибку доставки; запись остаётся Pending: $($_.Exception.Message)" "ERROR"
                }
                Write-Log "Результат отправки $alertType для '$($candidate.ReportName)' неопределён: $sendError. Автоматический повтор заблокирован." "ERROR"
            }

            if ($Limit -gt 0 -and $claimedCount -ge $Limit) {
                break SourceRow
            }
        }
    }

    Write-Log "Итоги: исходных строк=$($rows.Rows.Count), зарезервировано новых=$claimedCount, отправлено=$sentCount, пропущено=$skippedCount, ошибок=$failedCount."
}

$connection = $null
try {
    Write-Log "Начало выполнения. Mode=$Mode, Limit=$Limit."

    if ($Mode -eq "Test") {
        Invoke-SelfTests
        exit 0
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $connection = New-SqlConnection
    $connection.Open()
    Write-Log "Подключение к SQL $SqlServer/$SqlDatabase успешно."

    switch ($Mode) {
        "Diagnose" {
            Invoke-Diagnostics $connection
        }
        "Initialize" {
            Initialize-HistoryTable $connection
            Write-Log "Таблица [pbix].[AlertHistory] инициализирована. Сообщения не отправлялись."
        }
        "Send" {
            Invoke-Delivery $connection
        }
    }
}
catch {
    Write-Log "Критическая ошибка: $($_.Exception.Message)" "ERROR"
    exit 1
}
finally {
    if ($null -ne $connection) {
        $connection.Dispose()
    }
}
