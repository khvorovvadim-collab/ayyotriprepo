USE [ra];
GO

SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dnorm].[DB_DostavkaIM_PBI]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @BegDate date = DATEADD(month, -1, GETDATE());
    DECLARE @EndDate date = DATEADD(week, 3, GETDATE());
    DECLARE @EndDateExclusive date = DATEADD(day, 1, @EndDate);
    DECLARE @EmptyDate date = CONVERT(date, '19000101', 112);

    DROP TABLE IF EXISTS #DeliveryJournal;

    SELECT
        delivery.OrderId,
        STATUSDATE = MIN(journal.STATUSDATE)
    INTO #DeliveryJournal
    FROM [ax-db].[ALK12_ZBS].[dbo].[ALK_EShopSKKDeliveryTable] AS delivery
    INNER JOIN [ax-db].[ALK12_ZBS].[dbo].[ALK_EShopSKKDeliveryJournal] AS journal
        ON journal.ESBRequestid = delivery.ESBRequestid
        AND journal.CourierId = delivery.CourierId
    WHERE journal.STATUSALKOR = N'В пункте доставки'
        AND journal.createdDateTime >= DATEADD(day, -15, @BegDate)
        AND journal.createdDateTime < DATEADD(day, 15, @EndDate)
    GROUP BY delivery.OrderId;

    CREATE UNIQUE CLUSTERED INDEX IX_DeliveryJournal_OrderId
        ON #DeliveryJournal (OrderId);

    DROP TABLE IF EXISTS #LatestDelivery;

    SELECT
        ranked.OrderId,
        ranked.DeliveryDate,
        ranked.DeliveryTime,
        ranked.StatusCourierCompany,
        ranked.ESBRequestid,
        ranked.CourierId
    INTO #LatestDelivery
    FROM
    (
        SELECT
            delivery.OrderId,
            delivery.DeliveryDate,
            delivery.DeliveryTime,
            delivery.StatusCourierCompany,
            delivery.ESBRequestid,
            delivery.CourierId,
            RowNumber = ROW_NUMBER() OVER
            (
                PARTITION BY delivery.OrderId
                ORDER BY
                    DATEADD(second, delivery.DeliveryTime, delivery.DeliveryDate) DESC,
                    delivery.RECID DESC
            )
        FROM [AX-DB].[ALK12_ZBS].[dbo].[ALK_ESHOPSKKDELIVERYTABLE] AS delivery
        WHERE delivery.OrderId <> N''
            AND delivery.DeliveryDate >= DATEADD(month, -3, @BegDate)
            AND delivery.DeliveryDate < @EndDateExclusive
    ) AS ranked
    WHERE ranked.RowNumber = 1;

    CREATE UNIQUE CLUSTERED INDEX IX_LatestDelivery_OrderId
        ON #LatestDelivery (OrderId);

    DROP TABLE IF EXISTS #ETL_LOAD;

    SELECT
        [НЗ] = orders.ORDERIDEXTERNAL,
        [Заявка ИМ] = orders.OrderId,
        [Заказ на продажу] = orders.SalesId,
        [RT] = orders.REPORTTYPE,
        [DeliveryType] = orders.DeliveryType,
        [OS] = orderStatus.[name],
        [enumOS] = orders.ORDERSTATUS,
        [ASu] = orders.AMOUNTorder,
        [DFr] = COALESCE(
            NULLIF(CONVERT(date, orders.DeliveryDateTransfered), @EmptyDate),
            CONVERT(date, orders.DeliveryDateTimeTo)
        ),
        [DFa] = CASE
            WHEN orders.REPORTTYPE = 104
                AND COALESCE(CONVERT(date, orders.FACTDATEdelivery), @EmptyDate)
                    >= COALESCE(CONVERT(date, latest.DeliveryDate), @EmptyDate)
                THEN COALESCE(CONVERT(date, latest.DeliveryDate), @EmptyDate)
            WHEN history.DeliveredToStoreDateTime IS NOT NULL
                THEN CONVERT(date, DATEADD(hour, 3, history.DeliveredToStoreDateTime))
            ELSE CONVERT(date, orders.FACTDATEdelivery)
        END,
        [факт] = orders.FACTDATEdelivery,
        [Дата и время доставки факт] =
            DATEADD(second, latest.DeliveryTime, latest.DeliveryDate),
        [Статус] = latest.StatusCourierCompany,
        [ESBRequestid] = latest.ESBRequestid,
        [CourierId] = latest.CourierId,
        [KK] = orders.expresscompid,
        [КЛАДР] = orders.KLADRCity,
        [Дата-время отправки в комплектацию] =
            DATEADD(hour, 3, orders.FactDateTimeSendToAssemble),
        [Срок сборки заказа до] = DATEADD(hour, 3, orders.AssemblyUpDateTime),
        [Дата и время получения статуса Скомплектовано] =
            DATEADD(hour, 3, history.AssembledDateTime),
        [Дата и время доставки в магазин] =
            DATEADD(hour, 3, history.DeliveredToStoreDateTime),
        [Дата-время сборки заказа] =
            DATEADD(hour, 3, orders.AssembledDateTimeFact),
        [Плановая дата и время отгрузки] =
            DATEADD(second, orders.ShipmentTimePlan, orders.ShipmentDatePlan),
        [Дата-время отгрузки] =
            DATEADD(hour, 3, orders.FactDateTimeShipment),
        [Запрошенный срок доставки (начало интервала)] =
            DATEADD(hour, 3, orders.DeliveryDateTimeFrom),
        [Запрошенный срок доставки (окончание интервала)] =
            DATEADD(hour, 3, orders.DeliveryDateTimeTo),
        [Дата и время получения статуса Доставлен клиенту] =
            DATEADD(hour, 3, history.DeliveredToCustomerDateTime),
        [Склад комплектации] = orders.InventLocationPickingId,
        [Магазин выдачи] = orders.ShopId,
        [Зарезервировано с дефектурой] = lineFacts.IsReservedDefect,
        [Скомплектовано с дефектурой] = lineFacts.IsPickedDefect,
        [Перенос доставки] = CASE
            WHEN orders.DeliveryDateTransfered IS NULL
                OR CONVERT(date, orders.DeliveryDateTransfered) = @EmptyDate
                THEN 0
            ELSE 1
        END,
        [DPVZ] = CASE
            WHEN orders.REPORTTYPE IN (105, 106, 107, 108)
                THEN COALESCE(CONVERT(date, journal.STATUSDATE), @EmptyDate)
            ELSE @EmptyDate
        END,
        [Телефон клиента] = orders.ContactPhone,
        [Контактное лицо] = orders.ContactName
    INTO #ETL_LOAD
    FROM [AX-DB].[ALK12_ZBS].[dbo].[ALK_ESHOPORDERTABLE] AS orders
    LEFT JOIN [AX-DB].[ALK12_ZBS].[dbo].[ALK_ENUM_ALK_EShopOrderStatus] AS orderStatus
        ON orderStatus.code = orders.ORDERSTATUS
    LEFT JOIN #LatestDelivery AS latest
        ON latest.OrderId = orders.OrderId
    LEFT JOIN #DeliveryJournal AS journal
        ON journal.OrderId = orders.OrderId
    OUTER APPLY
    (
        SELECT
            DeliveredToStoreDateTime = MAX(
                CASE WHEN statusHistory.OrderStatus = 55
                    THEN statusHistory.PROCESSEDDATETIME END
            ),
            AssembledDateTime = MAX(
                CASE WHEN statusHistory.OrderStatus = 30
                    THEN statusHistory.PROCESSEDDATETIME END
            ),
            DeliveredToCustomerDateTime = MAX(
                CASE WHEN statusHistory.OrderStatus = 60
                    THEN statusHistory.PROCESSEDDATETIME END
            )
        FROM [ax-db].[ALK12_ZBS].[dbo].[ALK_EShopOrderTableStatusHistory] AS statusHistory
        WHERE statusHistory.OrderId = orders.OrderId
            AND statusHistory.OrderStatus IN (30, 55, 60)
            AND statusHistory.PARTITION = 5637144576
            AND statusHistory.DATAAREAID = N'dat'
    ) AS history
    OUTER APPLY
    (
        SELECT
            IsReservedDefect = MAX(orderLine.IsReservedDefect),
            IsPickedDefect = MAX(orderLine.IsPickedDefect)
        FROM [ax-db].[ALK12_ZBS].[dbo].[ALK_EShopOrderLine] AS orderLine
        WHERE orderLine.OrderId = orders.OrderId
    ) AS lineFacts
    WHERE orders.DeliveryDateTimeTo >= @BegDate
        AND orders.DeliveryDateTimeTo < @EndDateExclusive
        AND orders.PARTITION = 5637144576
        AND orders.DATAAREAID = N'dat';

    CREATE CLUSTERED INDEX IX_ETL_LOAD_OrderNumber
        ON #ETL_LOAD ([НЗ]);

    BEGIN TRANSACTION;

    DELETE target
    FROM [ra].[pbix].[db_IMdeliveryLoadInc] AS target
    WHERE target.[Запрошенный срок доставки (окончание интервала)]
            >= DATEADD(hour, 3, CONVERT(datetime, @BegDate))
        AND target.[Запрошенный срок доставки (окончание интервала)]
            < DATEADD(hour, 3, CONVERT(datetime, @EndDateExclusive));

    DELETE target
    FROM [ra].[pbix].[db_IMdeliveryLoadInc] AS target
    INNER JOIN #ETL_LOAD AS source
        ON source.[НЗ] = target.[Номер заказа расширенный];

    INSERT INTO [ra].[pbix].[db_IMdeliveryLoadInc]
    (
        [Номер заказа расширенный],
        [Заявка ИМ],
        [Заказ на продажу],
        [Метод доставки],
        [REPORTTYPE],
        [Метод доставки 2],
        [Источник комплектации],
        [Статус заказа],
        [Сумма заказа],
        [Доставить от],
        [КЛАДР],
        [Дата доставки факт],
        [Дата и время доставки факт],
        [Курьерская компания],
        [Дата доставки в ПВЗ],
        [Дата и время доставки в магазин],
        [Доставлен клиенту],
        [Скомплектован вовремя],
        [Отгружено вовремя],
        [Наличие интервала],
        [Доставлено в плановый интервал],
        [Доставлен в ПВЗ],
        [Доставлен вовремя],
        [Дата-время отправки в комплектацию],
        [Срок сборки заказа до],
        [Дата и время получения статуса Скомплектовано],
        [Дата-время сборки заказа],
        [Плановая дата и время отгрузки],
        [Дата-время отгрузки],
        [Запрошенный срок доставки (начало интервала)],
        [Запрошенный срок доставки (окончание интервала)],
        [Дата и время получения статуса Доставлен клиенту],
        [Перенос доставки],
        [Склад комплектации],
        [Город комплектации],
        [Регион комплектации],
        [Ареал комплектации],
        [Город магазина выдачи],
        [Регион магазина выдачи],
        [Ареал магазина выдачи],
        [Скомплектовано с дефектурой],
        [Зарезервировано с дефектурой],
        [Магазин выдачи],
        [OTIF основной],
        [OTIF light v1],
        [OTIF light v2],
        [Доставок в обещанный день и интервал времени],
        [Доставок в обещанный день],
        [Доставок в обещанный день или ранее],
        [Количество],
        [dwh_vreateddatetime],
        [Ранний привоз],
        [Телефон клиента],
        [Контактное лицо]
    )
    SELECT
        [Номер заказа расширенный] = source.[НЗ],
        source.[Заявка ИМ],
        source.[Заказ на продажу],
        [Метод доставки] = deliveryType.[name],
        [REPORTTYPE] = source.[RT],
        [Метод доставки 2] = CASE
            WHEN deliveryType.engname = N'PickingWrh' THEN N'Самовывоз 2.0'
            WHEN deliveryType.engname = N'PickingShop'
                AND deliveryType.[description] = N'C4' THEN N'Самовывоз 4.0'
            WHEN deliveryType.engname = N'PickingShop'
                AND deliveryType.[description] = N'C4.3' THEN N'Самовывоз 4.3'
            WHEN deliveryType.engname = N'AccPickingShop' THEN N'Экспресс С4.3'
            WHEN deliveryType.engname = N'FarmaPicking' THEN N'Аптечный самовывоз 4'
            WHEN deliveryType.engname = N'Shiping' THEN N'КД (курьерская доставка)'
            WHEN deliveryType.engname = N'AccShipping'
                THEN N'УКД (ускоренная курьерская доставка)'
            WHEN deliveryType.engname = N'ShippingShop' THEN N'Курьерка 4.3'
            WHEN deliveryType.engname = N'AccShippingShop' THEN N'Экспресс доставка'
            WHEN deliveryType.engname IN (N'FarmaShipping', N'FarmaShiping')
                THEN N'Аптечная курьерская доставка 4.3'
            WHEN deliveryType.engname = N'DBSShiping'
                THEN N'Курьерская доставка 4.3 Маркетплейс'
            WHEN deliveryType.engname = N'PickingPickPoint'
                THEN N'Самовывоз из пункта выдачи'
            WHEN deliveryType.engname = N'PickingPointFromShop'
                THEN N'Доставка из магазина-хаба в ПВЗ'
            ELSE N''
        END,
        [Источник комплектации] = CASE
            WHEN source.[RT] IN
                (0, 93, 94, 95, 96, 97, 105, 109, 110, 111, 112, 121, 122)
                THEN N'Склад'
            WHEN source.[RT] IN (91, 92, 99, 100, 103, 107, 117, 118, 120)
                THEN N'Магазин'
            WHEN source.[RT] = 104 THEN N'Магазин-Склад'
            ELSE CONVERT(varchar(12), source.[RT])
        END,
        [Статус заказа] = source.[OS],
        [Сумма заказа] = source.[ASu],
        [Доставить от] = source.[DFr],
        source.[КЛАДР],
        [Дата доставки факт] = source.[DFa],
        source.[Дата и время доставки факт],
        [Курьерская компания] = source.[KK],
        [Дата доставки в ПВЗ] = source.[DPVZ],
        source.[Дата и время доставки в магазин],
        [Доставлен клиенту] = CASE WHEN source.[enumOS] = 60 THEN 1 ELSE 0 END,
        [Скомплектован вовремя] = CASE
            WHEN source.[RT] NOT IN (93, 95, 96, 97, 105, 106, 109, 110)
                AND source.[Дата-время сборки заказа] IS NOT NULL
                AND source.[Дата-время сборки заказа] <= source.[Срок сборки заказа до]
                THEN 1
            WHEN source.[RT] IN (93, 95, 96, 97, 105, 106, 109, 110)
                AND source.[Дата и время получения статуса Скомплектовано] IS NOT NULL
                AND source.[Дата и время получения статуса Скомплектовано]
                    <= source.[Срок сборки заказа до]
                THEN 1
            ELSE 0
        END,
        [Отгружено вовремя] = CASE
            WHEN source.[RT] IN (91, 99) THEN 1
            WHEN source.[Дата-время отгрузки] IS NULL THEN 0
            WHEN source.[RT] IN (93, 95, 97, 105, 106, 109, 110, 117)
                AND CONVERT(date, source.[Дата-время отгрузки])
                    <= CONVERT(date, source.[Плановая дата и время отгрузки])
                THEN 1
            WHEN source.[RT] IN (92, 100, 103, 104, 120)
                AND source.[Дата-время отгрузки]
                    <= source.[Запрошенный срок доставки (окончание интервала)]
                THEN 1
            WHEN source.[Дата-время отгрузки]
                <= source.[Плановая дата и время отгрузки]
                THEN 1
            ELSE 0
        END,
        [Наличие интервала] = CASE
            WHEN source.[Запрошенный срок доставки (начало интервала)]
                <> source.[Запрошенный срок доставки (окончание интервала)]
                THEN N'Да'
            ELSE N'Нет'
        END,
        [Доставлено в плановый интервал] = CASE
            WHEN source.[Запрошенный срок доставки (начало интервала)]
                <> source.[Запрошенный срок доставки (окончание интервала)]
                AND source.[Дата и время получения статуса Доставлен клиенту]
                    BETWEEN source.[Запрошенный срок доставки (начало интервала)]
                        AND source.[Запрошенный срок доставки (окончание интервала)]
                THEN 1
            ELSE 0
        END,
        [Доставлен в ПВЗ] = CASE
            WHEN source.[RT] IN (105, 106, 107, 108)
                AND source.[DFa] = @EmptyDate
                AND source.[DPVZ] > @EmptyDate
                THEN 1
            ELSE 0
        END,
        [Доставлен вовремя] = CASE
            WHEN source.[RT] IN (105, 107)
                AND source.[DFa] > @EmptyDate
                AND source.[DPVZ] > @EmptyDate
                AND
                (
                    (source.[DFa] <= source.[DPVZ]
                        AND DATEDIFF(day, source.[DFr], source.[DFa]) <= 0)
                    OR
                    (source.[DFa] > source.[DPVZ]
                        AND DATEDIFF(day, source.[DFr], source.[DPVZ]) <= 0)
                )
                THEN 1
            WHEN source.[RT] IN (105, 107)
                AND source.[DFa] > @EmptyDate
                AND DATEDIFF(day, source.[DFr], source.[DFa]) <= 0
                THEN 1
            WHEN source.[RT] IN (105, 107)
                AND source.[DPVZ] > @EmptyDate
                AND DATEDIFF(day, source.[DFr], source.[DPVZ]) <= 0
                THEN 1
            WHEN source.[RT] NOT IN (105, 107)
                AND source.[DFa] > @EmptyDate
                AND DATEDIFF(day, source.[DFr], source.[DFa]) <= 0
                THEN 1
            ELSE 0
        END,
        source.[Дата-время отправки в комплектацию],
        source.[Срок сборки заказа до],
        source.[Дата и время получения статуса Скомплектовано],
        source.[Дата-время сборки заказа],
        source.[Плановая дата и время отгрузки],
        source.[Дата-время отгрузки],
        source.[Запрошенный срок доставки (начало интервала)],
        source.[Запрошенный срок доставки (окончание интервала)],
        source.[Дата и время получения статуса Доставлен клиенту],
        source.[Перенос доставки],
        source.[Склад комплектации],
        [Город комплектации] = pickingLocation.alk_tms_inventlocationcity,
        [Регион комплектации] = pickingLocation.ALK_TMS_INVENTLOCATIONREGION,
        [Ареал комплектации] = pickingLocation.ALK_AREAL,
        [Город магазина выдачи] = shopLocation.alk_tms_inventlocationcity,
        [Регион магазина выдачи] = shopLocation.ALK_TMS_INVENTLOCATIONREGION,
        [Ареал магазина выдачи] = shopLocation.ALK_AREAL,
        source.[Скомплектовано с дефектурой],
        source.[Зарезервировано с дефектурой],
        source.[Магазин выдачи],
        [OTIF основной] = CASE
            WHEN source.[Скомплектовано с дефектурой] = 1
                OR source.[Зарезервировано с дефектурой] = 1
                THEN 0
            WHEN source.[RT] IN (117, 118)
                AND source.[Дата и время доставки факт]
                    <= source.[Запрошенный срок доставки (окончание интервала)]
                AND CONVERT(date, source.[Дата и время доставки факт]) > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (91, 99)
                AND source.[Дата и время доставки в магазин]
                    <= source.[Запрошенный срок доставки (окончание интервала)]
                AND CONVERT(date, source.[Дата и время доставки в магазин]) > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (95, 96, 103, 104)
                AND CONVERT(date, source.[Дата и время доставки в магазин])
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND CONVERT(date, source.[Дата и время доставки в магазин]) > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (105, 106, 107, 108)
                AND source.[DPVZ]
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND source.[DPVZ] > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (105, 106, 107, 108)
                AND source.[DPVZ] = @EmptyDate
                AND source.[OS] IN (N'Доставлен клиенту', N'Отменен')
                AND CONVERT(date, source.[Дата и время получения статуса Доставлен клиенту])
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND CONVERT(date, source.[Дата и время получения статуса Доставлен клиенту])
                    > @EmptyDate
                THEN 1
            WHEN source.[RT] NOT IN
                (91, 95, 96, 99, 103, 104, 105, 106, 107, 108, 117, 118)
                AND source.[Дата и время доставки факт]
                    BETWEEN source.[Запрошенный срок доставки (начало интервала)]
                        AND source.[Запрошенный срок доставки (окончание интервала)]
                THEN 1
            ELSE 0
        END,
        [OTIF light v1] = CASE
            WHEN source.[Скомплектовано с дефектурой] = 1
                OR source.[Зарезервировано с дефектурой] = 1
                THEN 0
            WHEN source.[RT] IN (91, 95, 96, 99, 103, 104)
                AND CONVERT(date, source.[Дата и время доставки в магазин])
                    BETWEEN CONVERT(date, source.[Запрошенный срок доставки (начало интервала)])
                        AND CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                THEN 1
            WHEN source.[RT] IN (105, 106, 107, 108)
                AND source.[DPVZ]
                    BETWEEN CONVERT(date, source.[Запрошенный срок доставки (начало интервала)])
                        AND CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                THEN 1
            WHEN source.[RT] NOT IN (91, 95, 96, 99, 103, 104, 105, 106, 107, 108)
                AND CONVERT(date, source.[Дата и время доставки факт])
                    BETWEEN CONVERT(date, source.[Запрошенный срок доставки (начало интервала)])
                        AND CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                THEN 1
            ELSE 0
        END,
        [OTIF light v2] = CASE
            WHEN source.[Скомплектовано с дефектурой] = 1
                OR source.[Зарезервировано с дефектурой] = 1
                THEN 0
            WHEN source.[RT] IN (91, 95, 96, 99, 103, 104)
                AND CONVERT(date, source.[Дата и время доставки в магазин])
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND CONVERT(date, source.[Дата и время доставки в магазин]) > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (105, 106, 107, 108)
                AND source.[DPVZ]
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND source.[DPVZ] > @EmptyDate
                THEN 1
            WHEN source.[RT] NOT IN (91, 95, 96, 99, 103, 104, 105, 106, 107, 108)
                AND CONVERT(date, source.[Дата и время доставки факт])
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND CONVERT(date, source.[Дата и время доставки факт]) > @EmptyDate
                THEN 1
            ELSE 0
        END,
        [Доставок в обещанный день и интервал времени] = CASE
            WHEN source.[RT] IN (117, 118)
                AND source.[Дата и время доставки факт]
                    <= source.[Запрошенный срок доставки (окончание интервала)]
                AND CONVERT(date, source.[Дата и время доставки факт]) > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (91, 99)
                AND source.[Дата и время доставки в магазин]
                    <= source.[Запрошенный срок доставки (окончание интервала)]
                AND CONVERT(date, source.[Дата и время доставки в магазин]) > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (95, 96, 103, 104)
                AND CONVERT(date, source.[Дата и время доставки в магазин])
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND CONVERT(date, source.[Дата и время доставки в магазин]) > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (105, 106, 107, 108)
                AND source.[DPVZ]
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND source.[DPVZ] > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (105, 106, 107, 108)
                AND source.[DPVZ] = @EmptyDate
                AND source.[OS] IN (N'Доставлен клиенту', N'Отменен')
                AND CONVERT(date, source.[Дата и время получения статуса Доставлен клиенту])
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND CONVERT(date, source.[Дата и время получения статуса Доставлен клиенту])
                    > @EmptyDate
                THEN 1
            WHEN source.[RT] NOT IN
                (91, 95, 96, 99, 103, 104, 105, 106, 107, 108, 117, 118)
                AND source.[Дата и время доставки факт]
                    BETWEEN source.[Запрошенный срок доставки (начало интервала)]
                        AND source.[Запрошенный срок доставки (окончание интервала)]
                THEN 1
            ELSE 0
        END,
        [Доставок в обещанный день] = CASE
            WHEN source.[RT] IN (91, 95, 96, 99, 103, 104)
                AND CONVERT(date, source.[Дата и время доставки в магазин])
                    BETWEEN CONVERT(date, source.[Запрошенный срок доставки (начало интервала)])
                        AND CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                THEN 1
            WHEN source.[RT] IN (105, 106, 107, 108)
                AND source.[DPVZ]
                    BETWEEN CONVERT(date, source.[Запрошенный срок доставки (начало интервала)])
                        AND CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                THEN 1
            WHEN source.[RT] NOT IN (91, 95, 96, 99, 103, 104, 105, 106, 107, 108)
                AND CONVERT(date, source.[Дата и время доставки факт])
                    BETWEEN CONVERT(date, source.[Запрошенный срок доставки (начало интервала)])
                        AND CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                THEN 1
            ELSE 0
        END,
        [Доставок в обещанный день или ранее] = CASE
            WHEN source.[RT] IN (91, 95, 96, 99, 103, 104)
                AND CONVERT(date, source.[Дата и время доставки в магазин])
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND CONVERT(date, source.[Дата и время доставки в магазин]) > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (105, 106, 107, 108)
                AND source.[DPVZ]
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND source.[DPVZ] > @EmptyDate
                THEN 1
            WHEN source.[RT] NOT IN (91, 95, 96, 99, 103, 104, 105, 106, 107, 108)
                AND CONVERT(date, source.[Дата и время доставки факт])
                    <= CONVERT(date, source.[Запрошенный срок доставки (окончание интервала)])
                AND CONVERT(date, source.[Дата и время доставки факт]) > @EmptyDate
                THEN 1
            ELSE 0
        END,
        [Количество] = 1,
        [dwh_vreateddatetime] = GETDATE(),
        [Ранний привоз] = CASE
            WHEN source.[Скомплектовано с дефектурой] = 1
                OR source.[Зарезервировано с дефектурой] = 1
                THEN 0
            WHEN source.[RT] IN (91, 95, 96, 99, 103, 104)
                AND CONVERT(date, source.[Дата и время доставки в магазин])
                    <= CONVERT(date, source.[Запрошенный срок доставки (начало интервала)])
                AND CONVERT(date, source.[Дата и время доставки в магазин]) > @EmptyDate
                THEN 1
            WHEN source.[RT] IN (105, 106, 107, 108)
                AND source.[DPVZ]
                    <= CONVERT(date, source.[Запрошенный срок доставки (начало интервала)])
                AND source.[DPVZ] > @EmptyDate
                THEN 1
            WHEN source.[RT] NOT IN (91, 95, 96, 99, 103, 104, 105, 106, 107, 108)
                AND CONVERT(date, source.[Дата и время доставки факт])
                    <= CONVERT(date, source.[Запрошенный срок доставки (начало интервала)])
                AND CONVERT(date, source.[Дата и время доставки факт]) > @EmptyDate
                THEN 1
            ELSE 0
        END,
        source.[Телефон клиента],
        source.[Контактное лицо]
    FROM #ETL_LOAD AS source
    OUTER APPLY
    (
        SELECT TOP (1)
            enum.[name],
            enum.engname,
            enum.[description]
        FROM [ax-db].[ALK12_ZBS].[dbo].[ALK_ENUM_ALK_EShopDeliveryType] AS enum
        WHERE enum.code = source.[DeliveryType]
        ORDER BY enum.RECID DESC
    ) AS deliveryType
    OUTER APPLY
    (
        SELECT TOP (1)
            location.alk_tms_inventlocationcity,
            location.ALK_TMS_INVENTLOCATIONREGION,
            location.ALK_AREAL
        FROM [AX-DB].[ALK12_ZBS].[dbo].[InventLocation] AS location
        WHERE location.InventLocationId = source.[Склад комплектации]
            AND location.PARTITION = 5637144576
            AND location.DATAAREAID = N'dat'
        ORDER BY location.RECID DESC
    ) AS pickingLocation
    OUTER APPLY
    (
        SELECT TOP (1)
            location.alk_tms_inventlocationcity,
            location.ALK_TMS_INVENTLOCATIONREGION,
            location.ALK_AREAL
        FROM [AX-DB].[ALK12_ZBS].[dbo].[InventLocation] AS location
        WHERE location.InventLocationId = source.[Магазин выдачи]
            AND location.PARTITION = 5637144576
            AND location.DATAAREAID = N'dat'
        ORDER BY location.RECID DESC
    ) AS shopLocation;

    COMMIT TRANSACTION;

    DROP TABLE IF EXISTS #ETL_LOAD;
    DROP TABLE IF EXISTS #LatestDelivery;
    DROP TABLE IF EXISTS #DeliveryJournal;
END;
GO
