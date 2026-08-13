# Power BI alerts → Mattermost

`PowerBI_ALERT_Mattermost.ps1` проверяет ошибки обновления отчётов Power BI и
отправляет новые алерты в Mattermost. Скрипт совместим с Windows PowerShell 5.1.

## Почему старая версия отправляла сообщения повторно

В старой версии HTTP-запрос выполнялся до `INSERT` в `[pbix].[AlertHistory]`.
Обе операции находились в одном `try/catch`. Если сообщение успешно уходило, а
`INSERT` затем завершался ошибкой, таблица оставалась пустой. При следующем
запуске та же строка снова считалась новой.

Дополнительные проблемы старой версии:

- webhook с секретом хранился прямо в Git;
- индекс журнала не был уникальным;
- параллельные экземпляры могли отправлять одинаковые алерты;
- параметр `Limit` не использовался;
- ошибка и таймаут одной записи обрабатывались зависимо из-за `continue`;
- `DryRun` отключал проверку дублей и не тестировал реальный поток состояний.

Новая версия сначала резервирует алерт в журнале со статусом `Pending`, затем
выполняет HTTP-запрос и переводит запись в `Sent` либо `Failed`. Записи
`Pending` и `Sent` повторно не отправляются. Повтор `Failed` возможен только с
явным параметром `-RetryFailed`.

## Порядок проверки

Все команды следует выполнять на сервере с доступом к SQL Server. Первые три
режима не отправляют сообщения в Mattermost.

### 1. Локальные тесты

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\PowerBI_ALERT_Mattermost.ps1 -Mode Test
```

Тесты не подключаются к SQL и не выполняют HTTP-запросы. Они проверяют правила
формирования алертов, совместное событие Error+Timeout, границу таймаута,
UTF-8, отсутствие webhook в коде и безопасный режим по умолчанию.

### 2. Диагностика без изменений

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\PowerBI_ALERT_Mattermost.ps1 `
  -Mode Diagnose `
  -SqlServer REPORT-S `
  -SqlDatabase ra `
  -Limit 100 `
  -LogFile C:\Temp\DashboardAlerts-diagnostic.log
```

Режим читает источник и журнал, после чего выводит:

- количество исходных строк и потенциальных алертов;
- количество некорректных строк;
- наличие необходимых колонок и уникального индекса;
- количество дублей, `Pending` и `Failed`.

### 3. Инициализация журнала

Сначала сделайте резервную копию существующей таблицы. Затем выполните:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\PowerBI_ALERT_Mattermost.ps1 `
  -Mode Initialize `
  -SqlServer REPORT-S `
  -SqlDatabase ra
```

Режим создаёт или дополняет `[pbix].[AlertHistory]`, но ничего не отправляет.
Если в существующем журнале найдены одинаковые ключи
`SubscriptionID + StartTime + AlertType`, миграция останавливается. Такие строки
нужно проверить вручную; скрипт намеренно не удаляет историю автоматически.

Повторите `-Mode Diagnose` и убедитесь, что:

```text
существует=True, новых колонок=5/5, уникальный индекс=True
ключей-дублей=0
```

## Настройка реальной отправки

Webhook, который ранее находился в исходном файле, скомпрометирован историей
Git. Его необходимо отозвать в Mattermost и выпустить новый.

Задайте новый webhook только в учётной записи, запускающей SQL Agent/Task
Scheduler:

```powershell
$env:POWERBI_ALERT_MATTERMOST_WEBHOOK = "https://mattermost.example/hooks/NEW_SECRET"
```

Для постоянной настройки используйте защищённую переменную среды либо
секрет-хранилище вашей инфраструктуры. Не добавляйте значение в Git.

После успешных `Test`, `Diagnose` и `Initialize` выполните контролируемый запуск
с небольшим лимитом:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\PowerBI_ALERT_Mattermost.ps1 `
  -Mode Send `
  -SqlServer REPORT-S `
  -SqlDatabase ra `
  -Limit 1
```

Проверьте одну запись в Mattermost и соответствующую строку со статусом `Sent`
в `[pbix].[AlertHistory]`. После этого уберите `-Limit 1` из планового задания.

Не используйте `-RetryFailed`, пока не проверите причину ошибки и отсутствие
сообщения в Mattermost: webhook не поддерживает идемпотентный ключ, поэтому
абсолютная гарантия exactly-once после неопределённого сетевого сбоя невозможна.
