# ============================================================
# Скрипт: Send-DashboardAlerts.ps1
# Версия: возврат к работающей логике, исправлена кодировка
# ============================================================

$DryRun = $false          # false – реальная отправка
$Limit = 0                # 0 – все записи

$SQLServer = "REPORT-S"
$SQLDatabase = "ra"
$ConnectionString = "Server=$SQLServer;Database=$SQLDatabase;Integrated Security=SSPI;"

$WebhookUrl = "https://mattermost.letuin.ru/hooks/7kby8btbgp8p7myze3dw5iea4c"

$LogFile = "\\Report-s\f$\Project\Logs\DashboardAlerts.log"
$LogDir = Split-Path $LogFile -Parent
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Entry = "[$Timestamp] [$Level] $Message"
    try { Add-Content -Path $LogFile -Value $Entry -ErrorAction Stop } catch {}
    Write-Host $Entry
}

function Get-Value {
    param([System.Data.DataRow]$Row, [string]$ColumnName, [object]$Default = $null)
    if ($Row.IsNull($ColumnName)) { return $Default } else { return $Row[$ColumnName] }
}

# Запрос (без фильтра по AlertHistory – фильтрация будет через проверку дублей в коде)
$SQLQuery = @"
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
')
"@

try {
    Write-Log "=== НАЧАЛО ВЫПОЛНЕНИЯ ==="
    Write-Log "Dry-Run: $DryRun"

    # Принудительно включаем TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $SqlConnection.Open()
    Write-Log "Подключение к SQL успешно."

    # Создание таблицы AlertHistory (если нет)
    $CreateTableQuery = @"
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'pbix')
    EXEC('CREATE SCHEMA pbix');
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[pbix].[AlertHistory]') AND type = N'U')
BEGIN
    CREATE TABLE [pbix].[AlertHistory] (
        [Id] INT IDENTITY(1,1) PRIMARY KEY,
        [SubscriptionID] UNIQUEIDENTIFIER NOT NULL,
        [StartTime] DATETIME NOT NULL,
        [EndTime] DATETIME NOT NULL,
        [DurationSeconds] INT NOT NULL,
        [AlertType] VARCHAR(20) NOT NULL,
        [SentDate] DATETIME DEFAULT GETDATE()
    );
    CREATE INDEX IX_AlertHistory_SubscriptionID_StartTime_AlertType 
        ON [pbix].[AlertHistory](SubscriptionID, StartTime, AlertType);
END
"@
    $CreateCmd = New-Object System.Data.SqlClient.SqlCommand($CreateTableQuery, $SqlConnection)
    $CreateCmd.ExecuteNonQuery() | Out-Null
    Write-Log "Таблица [pbix].[AlertHistory] проверена/создана."

    # Получение данных
    $SqlCommand = New-Object System.Data.SqlClient.SqlCommand($SQLQuery, $SqlConnection)
    $SqlCommand.CommandTimeout = 120
    $SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($SqlCommand)
    $DataTable = New-Object System.Data.DataTable
    $SqlAdapter.Fill($DataTable) | Out-Null

    Write-Log "Получено $($DataTable.Rows.Count) записей."

    if ($DataTable.Rows.Count -eq 0) {
        Write-Log "Нет данных." "INFO"
        $SqlConnection.Close()
        exit 0
    }

    $InsertQuery = @"
INSERT INTO [pbix].[AlertHistory] (SubscriptionID, StartTime, EndTime, DurationSeconds, AlertType)
VALUES (@SubscriptionID, @StartTime, @EndTime, @DurationSeconds, @AlertType);
"@
    $InsertCmd = New-Object System.Data.SqlClient.SqlCommand($InsertQuery, $SqlConnection)

    $TotalProcessed = 0
    $SentCount = 0

    foreach ($Row in $DataTable.Rows) {
        $TotalProcessed++
        $SubscriptionID = Get-Value -Row $Row -ColumnName "SubscriptionID" -Default ([guid]::Empty)
        $StartTime = Get-Value -Row $Row -ColumnName "StartTime" -Default (Get-Date)
        $EndTime = Get-Value -Row $Row -ColumnName "EndTime" -Default (Get-Date)
        $DurationSec = [int](Get-Value -Row $Row -ColumnName "DurationSeconds" -Default 0)
        $DurationMin = [int](Get-Value -Row $Row -ColumnName "DurationMinutes" -Default 0)
        $ReportName = Get-Value -Row $Row -ColumnName "ReportName" -Default ""
        $ReportPath = Get-Value -Row $Row -ColumnName "ReportPath" -Default ""
        $Status = [int](Get-Value -Row $Row -ColumnName "status" -Default 0)
        $MessageText = Get-Value -Row $Row -ColumnName "Message" -Default ""
        $Details = Get-Value -Row $Row -ColumnName "Details" -Default ""

        $isError = ($Status -eq 2)
        $isTimeout = ($DurationSec -gt 10800)

        if (-not ($isError -or $isTimeout)) { continue }

        # ---- Проверка дублей (если не DryRun) ----
        if (-not $DryRun) {
            $CheckQuery = "SELECT COUNT(*) FROM [pbix].[AlertHistory] WHERE SubscriptionID = @SubscriptionID AND StartTime = @StartTime AND EndTime = @EndTime AND AlertType = @AlertType"
            $CheckCmd = New-Object System.Data.SqlClient.SqlCommand($CheckQuery, $SqlConnection)
            $CheckCmd.Parameters.AddWithValue("@SubscriptionID", $SubscriptionID) | Out-Null
            $CheckCmd.Parameters.AddWithValue("@StartTime", $StartTime) | Out-Null
            $CheckCmd.Parameters.AddWithValue("@EndTime", $EndTime) | Out-Null
        }

        # ---- Ошибка ----
        if ($isError) {
            if (-not $DryRun) {
                $CheckCmd.Parameters.Clear()
                $CheckCmd.Parameters.AddWithValue("@SubscriptionID", $SubscriptionID) | Out-Null
                $CheckCmd.Parameters.AddWithValue("@StartTime", $StartTime) | Out-Null
                $CheckCmd.Parameters.AddWithValue("@EndTime", $EndTime) | Out-Null
                $CheckCmd.Parameters.AddWithValue("@AlertType", "Error") | Out-Null
                if ($CheckCmd.ExecuteScalar() -gt 0) {
                    Write-Log "Алерт 'Ошибка' для '$ReportName' уже отправлен, пропускаем." "DEBUG"
                    continue
                }
            }

            $AlertText = @"
**Ошибка обновления дашборда!**

- **Название:** $ReportName
- **Путь:** $ReportPath
- **SubscriptionID:** $SubscriptionID
- **Время начала:** $StartTime
- **Время окончания:** $EndTime
- **Длительность:** $DurationMin мин. ($DurationSec сек.)
- **Статус:** $Status (ошибка)
- **Сообщение:** $MessageText
- **Детали:** $Details
"@

            if ($DryRun) {
                Write-Log "[DRY-RUN] $AlertText" "INFO"
            } else {
                try {
                    $body = @{ text = $AlertText } | ConvertTo-Json -Compress
                    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $Response = Invoke-WebRequest -Uri $WebhookUrl `
                        -Method Post `
                        -ContentType "application/json; charset=utf-8" `
                        -Body $bodyBytes `
                        -TimeoutSec 30
                    Write-Log "Алерт 'Ошибка' для '$ReportName' отправлен (статус $($Response.StatusCode))." "INFO"
                    $SentCount++

                    $InsertCmd.Parameters.Clear()
                    $InsertCmd.Parameters.AddWithValue("@SubscriptionID", $SubscriptionID) | Out-Null
                    $InsertCmd.Parameters.AddWithValue("@StartTime", $StartTime) | Out-Null
                    $InsertCmd.Parameters.AddWithValue("@EndTime", $EndTime) | Out-Null
                    $InsertCmd.Parameters.AddWithValue("@DurationSeconds", $DurationSec) | Out-Null
                    $InsertCmd.Parameters.AddWithValue("@AlertType", "Error") | Out-Null
                    $InsertCmd.ExecuteNonQuery() | Out-Null
                } catch {
                    Write-Log "Ошибка отправки алерта 'Ошибка' для '$ReportName': $_" "ERROR"
                }
            }
        }

        # ---- Превышение времени ----
        if ($isTimeout) {
            if (-not $DryRun) {
                $CheckCmd.Parameters.Clear()
                $CheckCmd.Parameters.AddWithValue("@SubscriptionID", $SubscriptionID) | Out-Null
                $CheckCmd.Parameters.AddWithValue("@StartTime", $StartTime) | Out-Null
                $CheckCmd.Parameters.AddWithValue("@EndTime", $EndTime) | Out-Null
                $CheckCmd.Parameters.AddWithValue("@AlertType", "Timeout") | Out-Null
                if ($CheckCmd.ExecuteScalar() -gt 0) {
                    Write-Log "Алерт 'Превышение времени' для '$ReportName' уже отправлен, пропускаем." "DEBUG"
                    continue
                }
            }

            $AlertText = @"
**Превышение времени обновления дашборда!**

- **Название:** $ReportName
- **Путь:** $ReportPath
- **SubscriptionID:** $SubscriptionID
- **Время начала:** $StartTime
- **Время окончания:** $EndTime
- **Длительность:** $DurationMin мин. ($DurationSec сек.) – превышает 3 часа
- **Статус:** $Status
- **Сообщение:** $MessageText
- **Детали:** $Details
"@

            if ($DryRun) {
                Write-Log "[DRY-RUN] $AlertText" "INFO"
            } else {
                try {
                    $body = @{ text = $AlertText } | ConvertTo-Json -Compress
                    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $Response = Invoke-WebRequest -Uri $WebhookUrl `
                        -Method Post `
                        -ContentType "application/json; charset=utf-8" `
                        -Body $bodyBytes `
                        -TimeoutSec 30
                    Write-Log "Алерт 'Превышение времени' для '$ReportName' отправлен (статус $($Response.StatusCode))." "INFO"
                    $SentCount++

                    $InsertCmd.Parameters.Clear()
                    $InsertCmd.Parameters.AddWithValue("@SubscriptionID", $SubscriptionID) | Out-Null
                    $InsertCmd.Parameters.AddWithValue("@StartTime", $StartTime) | Out-Null
                    $InsertCmd.Parameters.AddWithValue("@EndTime", $EndTime) | Out-Null
                    $InsertCmd.Parameters.AddWithValue("@DurationSeconds", $DurationSec) | Out-Null
                    $InsertCmd.Parameters.AddWithValue("@AlertType", "Timeout") | Out-Null
                    $InsertCmd.ExecuteNonQuery() | Out-Null
                } catch {
                    Write-Log "Ошибка отправки алерта 'Превышение времени' для '$ReportName': $_" "ERROR"
                }
            }
        }
    }

    $SqlConnection.Close()
    Write-Log "=== ИТОГИ ==="
    Write-Log "Всего обработано записей: $TotalProcessed"
    Write-Log "Отправлено алертов: $SentCount"
    Write-Log "=== КОНЕЦ ==="

} catch {
    Write-Log "Критическая ошибка: $_" "ERROR"
    if ($SqlConnection.State -eq 'Open') { $SqlConnection.Close() }
    exit 1
}