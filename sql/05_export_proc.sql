-- The one procedure that shapes the JSON artifact. No transformation
-- logic lives in the browser: this is already exactly the front end's
-- consumption shape, including the flight-level granularity the
-- load-factor slider will need later to re-scale client-side.
--
-- One location per call, one JSON file per location (see
-- scripts/export_forecast.sh) — not one combined artifact for every
-- location, so switching locations in the UI is just fetching a
-- different small static file, the same "never query the database at
-- request time" rule this project has followed from the start.

USE Inbound;
GO

CREATE OR ALTER PROCEDURE export.GetForecastJson
    @LocationId INT = 1,    -- defaults to DTW A36
    @AsOfDate DATE = NULL   -- defaults to today; pass explicitly to pin a demo run against a specific window
AS
BEGIN
    SET NOCOUNT ON;
    SET DATEFIRST 7;  -- makes DATEPART(WEEKDAY, d) - 1 reliably 0=Sunday..6=Saturday, matching cfg.OpenHours

    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSDATETIME() AS DATE);

    DECLARE @OrderCycleDays INT, @WindowCount INT;
    SELECT @OrderCycleDays = OrderCycleDays, @WindowCount = WindowCount FROM cfg.OrderCycle;
    DECLARE @WindowDays INT = @OrderCycleDays * 2;
    DECLARE @RangeDays INT = @WindowDays * @WindowCount;
    DECLARE @RangeStart DATE = @AsOfDate;
    DECLARE @RangeEnd DATE = DATEADD(DAY, @RangeDays - 1, @AsOfDate);
    DECLARE @GeneratedAt DATETIME2(0) = SYSUTCDATETIME();

    -- Materialize the model output for just this window before assembling
    -- JSON. mdl.FlightHourDetail is a view stacked on a dwell-minute
    -- expansion (mdl.FlightDwell cross-joins cfg.Tally against every
    -- flight); at demo-dataset scale (~650 flights) the correlated
    -- subqueries below re-evaluating that chain per hour was fast enough
    -- to ignore, but at live-ingest scale (~6,700 flights) each one took
    -- ~1 second — recomputing the full model from scratch ~250+ times
    -- (14+ days x ~18 hours) rather than once. Materializing once into
    -- indexed temp tables turns those re-evaluations into index seeks.
    -- Scoped by LocationId too, now that one flight can produce rows for
    -- more than one location.
    SELECT *
    INTO #FlightHours
    FROM mdl.FlightHourDetail
    WHERE LocationId = @LocationId AND TrafficDate BETWEEN @RangeStart AND @RangeEnd;
    CREATE CLUSTERED INDEX IX_FlightHours ON #FlightHours (TrafficDate, TrafficHour, ScheduledTime);

    SELECT *
    INTO #HourlyIdx
    FROM mdl.HourlyIndex
    WHERE LocationId = @LocationId AND TrafficDate BETWEEN @RangeStart AND @RangeEnd;
    CREATE UNIQUE CLUSTERED INDEX IX_HourlyIdx ON #HourlyIdx (TrafficDate, TrafficHour);

    SELECT *
    INTO #DayRoll
    FROM mdl.DayRollup
    WHERE LocationId = @LocationId AND TrafficDate BETWEEN @RangeStart AND @RangeEnd;
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
        JOIN cfg.OpenHours oh ON oh.LocationId = @LocationId AND oh.DayOfWeek = DATEPART(WEEKDAY, ds.TrafficDate) - 1
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
        @WindowDays AS windowDays,
        (SELECT DefaultLoadFactor FROM cfg.LoadFactorDefault) AS defaultLoadFactor,
        JSON_QUERY((
            SELECT loc.LocationId AS locationId, loc.AirportCode AS airportCode, loc.GateLabel AS gateLabel,
                   loc.DisplayName AS displayName, loc.TerminalName AS terminalName, loc.City AS city
            FROM cfg.Location loc WHERE loc.LocationId = @LocationId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        )) AS location,
        JSON_QUERY((
            SELECT DayOfWeek AS dayOfWeek, OpenHour AS openHour, CloseHour AS closeHour
            FROM cfg.OpenHours WHERE LocationId = @LocationId ORDER BY DayOfWeek
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
                        -- Only flights with a resolved gate (ZoneName =
                        -- 'home') are itemized — a flight we can't place is
                        -- weaker evidence than one at a real gate, and
                        -- mixing them flattens a distinction worth keeping.
                        -- Unresolved-but-material flights (still >= 0.5
                        -- exposure, just via an airline's empirical prior
                        -- rather than a known gate — see
                        -- mdl.FlightExposure's AirlineGeometryPrior)
                        -- collapse into inferredFlightCount/inferredExposure
                        -- below instead of a long, low-confidence tail of
                        -- individually-listed guesses.
                        --
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
                                fhd.ScheduledTime AS scheduledTime,
                                fhd.AircraftModelCode AS aircraftType,
                                fhd.Seats AS seats,
                                fhd.LoadFactor AS loadFactor,
                                fhd.Passengers AS passengers,
                                fhd.Gate AS gate,
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
                              -- Itemized = a resolved, non-'unknown' zone.
                              -- Not literally "= 'home'": DTW's zone names
                              -- are 'south'/'center'/'terminal-tram'/
                              -- 'far-north', not 'home' — only DFW/IAD use
                              -- that name. 'unknown' is the one zone name
                              -- every location shares, so it's what this
                              -- checks against instead of a location-
                              -- specific zone name that doesn't generalize.
                              AND fhd.ZoneName <> 'unknown'
                              -- Excludes flights that would display as "0
                              -- past this location" (other-terminal gates,
                              -- which are correctly zero-weight but aren't
                              -- "driving" anything here, plus the occasional
                              -- genuinely tiny tail-end-of-window
                              -- contribution). The aggregate index this
                              -- hour shows is untouched — it still sums
                              -- every flight's real contribution; this
                              -- only trims which flights are worth
                              -- listing in the drill-down.
                              AND fhd.ExposureAtHour >= 0.5
                            ORDER BY fhd.ScheduledTime
                            -- INCLUDE_NULL_VALUES: durationMinutes is NULL
                            -- for live-ingested flights (Aviation Edge has
                            -- no elapsed-time field). Without this, FOR
                            -- JSON PATH drops the key entirely rather than
                            -- emitting null, so the front end would see
                            -- `undefined` instead of the `null` its type
                            -- declares — silently wrong rather than absent.
                            FOR JSON PATH, INCLUDE_NULL_VALUES
                        ), '[]')) AS flights,
                        (SELECT COUNT(*) FROM #FlightHours fhd
                         WHERE fhd.TrafficDate = hsh.TrafficDate AND fhd.TrafficHour = hsh.TrafficHour
                           AND fhd.ZoneName = 'unknown' AND fhd.ExposureAtHour >= 0.5) AS inferredFlightCount,
                        CAST(COALESCE((SELECT SUM(fhd.ExposureAtHour) FROM #FlightHours fhd
                         WHERE fhd.TrafficDate = hsh.TrafficDate AND fhd.TrafficHour = hsh.TrafficHour
                           AND fhd.ZoneName = 'unknown' AND fhd.ExposureAtHour >= 0.5), 0) AS DECIMAL(10,4)) AS inferredExposure
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

-- Small, separate artifact listing every active location, so the front
-- end's location picker can show "what else is available" without
-- fetching every location's (much larger) forecast file just to list
-- their names. Each location's own forecast-<code>.json still carries its
-- own location object inline (see above), so the picker never blocks
-- rendering the currently-loaded location while it works out what else
-- to offer.
CREATE OR ALTER PROCEDURE export.GetLocationManifest
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        LocationId AS locationId,
        AirportCode AS airportCode,
        GateLabel AS gateLabel,
        DisplayName AS displayName,
        TerminalName AS terminalName,
        City AS city,
        -- Matches the file name scripts/export_forecast.sh writes for this
        -- location, computed once here rather than re-derived by hand in
        -- both the export script and the front end.
        LOWER(AirportCode + '-' + REPLACE(GateLabel, ' ', '')) AS forecastFile
    FROM cfg.Location
    WHERE IsActive = 1
    ORDER BY LocationId
    FOR JSON PATH;
END
GO
