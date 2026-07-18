-- The one procedure that shapes the JSON artifact. No transformation
-- logic lives in the browser: this is already exactly the front end's
-- consumption shape, including the flight-level granularity the
-- load-factor slider will need later to re-scale client-side.

USE Inbound;
GO

CREATE OR ALTER PROCEDURE export.GetForecastJson
    @AsOfDate DATE = NULL   -- defaults to today; pass explicitly to pin a demo run against a specific window
AS
BEGIN
    SET NOCOUNT ON;
    SET DATEFIRST 7;  -- makes DATEPART(WEEKDAY, d) - 1 reliably 0=Sunday..6=Saturday, matching cfg.OpenHours

    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSDATETIME() AS DATE);

    DECLARE @OrderCycleDays INT = (SELECT OrderCycleDays FROM cfg.OrderCycle);
    DECLARE @RangeDays INT = @OrderCycleDays * 2;
    DECLARE @RangeStart DATE = @AsOfDate;
    DECLARE @RangeEnd DATE = DATEADD(DAY, @RangeDays - 1, @AsOfDate);
    DECLARE @GeneratedAt DATETIME2(0) = SYSUTCDATETIME();

    -- Materialize the model output for just this window before assembling
    -- JSON. mdl.FlightHourDetail is a view stacked on a dwell-minute
    -- expansion (mdl.FlightMinuteWeight cross-joins cfg.Tally against every
    -- flight); at demo-dataset scale (~650 flights) the correlated
    -- subqueries below re-evaluating that chain per hour was fast enough
    -- to ignore, but at live-ingest scale (~6,700 flights) each one took
    -- ~1 second — recomputing the full model from scratch ~250 times (14
    -- days x ~18 hours) rather than once. Materializing once into indexed
    -- temp tables turns those 250 re-evaluations into 250 index seeks.
    SELECT *
    INTO #FlightHours
    FROM mdl.FlightHourDetail
    WHERE TrafficDate BETWEEN @RangeStart AND @RangeEnd;
    CREATE CLUSTERED INDEX IX_FlightHours ON #FlightHours (TrafficDate, TrafficHour, DtwScheduledTime);

    SELECT *
    INTO #HourlyIdx
    FROM mdl.HourlyIndex
    WHERE TrafficDate BETWEEN @RangeStart AND @RangeEnd;
    CREATE UNIQUE CLUSTERED INDEX IX_HourlyIdx ON #HourlyIdx (TrafficDate, TrafficHour);

    SELECT *
    INTO #DayRoll
    FROM mdl.DayRollup
    WHERE TrafficDate BETWEEN @RangeStart AND @RangeEnd;
    CREATE UNIQUE CLUSTERED INDEX IX_DayRoll ON #DayRoll (TrafficDate);

    ;WITH DateSpine AS (
        SELECT DATEADD(DAY, t.n, @AsOfDate) AS TrafficDate
        FROM cfg.Tally t
        WHERE t.n < @RangeDays
    ),
    DayShape AS (
        SELECT
            ds.TrafficDate,
            DATENAME(WEEKDAY, ds.TrafficDate) AS DayOfWeekName,
            oh.OpenHour,
            oh.CloseHour
        FROM DateSpine ds
        JOIN cfg.OpenHours oh ON oh.DayOfWeek = DATEPART(WEEKDAY, ds.TrafficDate) - 1
    ),
    HourSpine AS (
        -- Reuses cfg.Tally (already sized 0-180) as the hour-of-day spine too;
        -- open-hour bounds never exceed 23, well within its range.
        SELECT dshp.TrafficDate, t.n AS TrafficHour
        FROM DayShape dshp
        JOIN cfg.Tally t ON t.n BETWEEN dshp.OpenHour AND dshp.CloseHour - 1
    ),
    HourShape AS (
        SELECT
            hs.TrafficDate,
            hs.TrafficHour,
            COALESCE(
                (SELECT TOP 1 dw.Daypart FROM cfg.DaypartWindow dw
                 WHERE hs.TrafficHour BETWEEN dw.StartHour AND dw.EndHour),
                'off'
            ) AS Daypart,
            COALESCE(hi.TrafficIndex, 0) AS TrafficIndex
        FROM HourSpine hs
        LEFT JOIN #HourlyIdx hi
            ON hi.TrafficDate = hs.TrafficDate AND hi.TrafficHour = hs.TrafficHour
    )
    SELECT
        @GeneratedAt AS generatedAt,
        'SQL Server 2022 (Aviation Edge live)' AS source,
        @OrderCycleDays AS orderCycleDays,
        (SELECT DefaultLoadFactor FROM cfg.LoadFactorDefault) AS defaultLoadFactor,
        JSON_QUERY((
            SELECT DayOfWeek AS dayOfWeek, OpenHour AS openHour, CloseHour AS closeHour
            FROM cfg.OpenHours ORDER BY DayOfWeek
            FOR JSON PATH
        )) AS openHoursByDayOfWeek,
        JSON_QUERY((
            SELECT Daypart AS daypart, StartHour AS startHour, EndHour AS endHour
            FROM cfg.DaypartWindow ORDER BY StartHour
            FOR JSON PATH
        )) AS daypartWindows,
        JSON_QUERY((
            SELECT
                dshp.TrafficDate AS date,
                dshp.DayOfWeekName AS dayOfWeek,
                dshp.OpenHour AS openHour,
                dshp.CloseHour AS closeHour,
                dr.DayIndex AS dayIndex,
                dr.PeakHour AS peakHour,
                JSON_QUERY((
                    SELECT
                        hsh.TrafficHour AS hour,
                        hsh.Daypart AS daypart,
                        hsh.TrafficIndex AS [index],
                        -- COALESCE to '[]' because FOR JSON PATH omits the key entirely
                        -- (not even a JSON null) when the subquery returns no rows, and
                        -- the front end should never have to branch on a missing key.
                        JSON_QUERY(COALESCE((
                            SELECT
                                fhd.FlightId AS flightId,
                                fhd.AirlineName AS airline,
                                fhd.AirlineIataCode AS airlineIataCode,
                                fhd.FlightNumber AS flightNumber,
                                fhd.Direction AS direction,
                                fhd.DtwScheduledTime AS scheduledTime,
                                fhd.AircraftModelCode AS aircraftType,
                                fhd.Seats AS seats,
                                fhd.LoadFactor AS loadFactor,
                                fhd.Passengers AS passengers,
                                fhd.DtwGate AS gate,
                                fhd.ZoneName AS gateZone,
                                fhd.GeometryWeight AS geometryWeight,
                                fhd.ExposureAtHour AS passengersPastA36,
                                fhd.DwellFraction AS dwellFraction,
                                fhd.OtherAirportCode AS otherAirportCode,
                                fhd.OtherAirportCity AS otherAirportCity,
                                fhd.DurationMinutes AS durationMinutes,
                                fhd.WindowStartTime AS impactWindowStart,
                                fhd.WindowEndTime AS impactWindowEnd
                            FROM #FlightHours fhd
                            WHERE fhd.TrafficDate = hsh.TrafficDate AND fhd.TrafficHour = hsh.TrafficHour
                              -- Excludes flights that would display as "0
                              -- past A36" (other-terminal gates, which are
                              -- correctly zero-weight but aren't "driving"
                              -- anything at A36, plus the occasional
                              -- genuinely tiny tail-end-of-window
                              -- contribution). The aggregate index this
                              -- hour shows is untouched — it still sums
                              -- every flight's real contribution; this
                              -- only trims which flights are worth
                              -- listing in the drill-down.
                              AND fhd.ExposureAtHour >= 0.5
                            ORDER BY fhd.DtwScheduledTime
                            -- INCLUDE_NULL_VALUES: durationMinutes is NULL
                            -- for live-ingested flights (Aviation Edge has
                            -- no elapsed-time field). Without this, FOR
                            -- JSON PATH drops the key entirely rather than
                            -- emitting null, so the front end would see
                            -- `undefined` instead of the `null` its type
                            -- declares — silently wrong rather than absent.
                            FOR JSON PATH, INCLUDE_NULL_VALUES
                        ), '[]')) AS flights
                    FROM HourShape hsh
                    WHERE hsh.TrafficDate = dshp.TrafficDate
                    ORDER BY hsh.TrafficHour
                    FOR JSON PATH
                )) AS hours
            FROM DayShape dshp
            LEFT JOIN #DayRoll dr ON dr.TrafficDate = dshp.TrafficDate
            ORDER BY dshp.TrafficDate
            FOR JSON PATH
        )) AS days
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;

    DROP TABLE #FlightHours;
    DROP TABLE #HourlyIdx;
    DROP TABLE #DayRoll;
END
GO
