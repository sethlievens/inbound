-- The exposure model. Views only, set-based throughout — no cursors, no
-- row-by-row loops. Comments explain the model the way the brief and
-- .claude/rules/sql.md explain it, since this is the piece most likely
-- to be read by whoever is hiring the SQL developer who wrote it.
--
-- Multi-location note: a physical flight's *dwell timing* (when its
-- passengers are in motion) is a fact about the flight alone. Its
-- *exposure* (how much of that traffic counts, and toward which store)
-- depends on which location is asking, since DFW's A8 and B4 weight the
-- same DFW flight differently. The view cascade below keeps those two
-- facts separate for as long as possible — dwell timing is computed once
-- per flight in mdl.FlightDwell, and only fans out per (flight, location)
-- pair at mdl.FlightHourDetail, where the two are finally multiplied
-- together. Recomputing the triangular dwell curve twice for the same
-- DFW flight, once per store, would be both wasteful and pointless: the
-- shape never differs, only the magnitude it gets multiplied against does.

USE Inbound;
GO

-- ============================================================
-- mdl.FlightExposure
--   Per (flight, location): Exposure = (seats * loadFactor) * geometryWeight.
--   geometryWeight is looked up as a single 0-1 value per gate zone —
--   never decomposed into separate distance/probability factors, which
--   would double-count distance (see cfg.GateZoneWeight). One row per
--   flight per *active* location at that flight's airport — a DFW flight
--   fans out to both DFW-A8 and DFW-B4's rows here, each with its own
--   geometry weight and Exposure; a DTW flight only has one active DTW
--   location today so it doesn't fan out in practice, but nothing here
--   assumes that stays true.
-- ============================================================
CREATE OR ALTER VIEW mdl.FlightExposure AS
WITH BestHistoricalGate AS (
    -- A live schedule this far out often has no gate yet (~47% blank in an
    -- early sample). Rather than let that silently zero out the flight's
    -- exposure, fall back to whichever gate that same recurring flight
    -- number has actually been seen at most often in past ingests — see
    -- stg.GateHistory. ROW_NUMBER picks the single best-observed gate per
    -- flight number/direction so the join below can't fan out multiple rows.
    -- Scoped by AirportCode: a flight number is only ever meaningful within
    -- one airport's schedule, and different airports could theoretically
    -- reuse the same flight number for an unrelated flight.
    --
    -- Checked against real accumulated history: gate assignment at DTW is
    -- much less stable per flight number than this mechanism assumed —
    -- about half of flight number/direction pairs have already been seen
    -- at more than one gate, and for those, the top pick is only right
    -- about 53% of the time on average (as low as 25% for some flights).
    -- A confident-sounding single gate that's more likely wrong than right
    -- is worse than no gate at all, so Confidence gates whether the join
    -- below trusts this pick: only when the top gate accounts for at least
    -- 60% of that flight's observed history. Below that, the flight falls
    -- through to blank gate and the honest 'unknown' zone average instead
    -- of a specific guess dressed up as a fact.
    SELECT
        AirportCode, FlightNumber, Direction, Gate,
        ROW_NUMBER() OVER (PARTITION BY AirportCode, FlightNumber, Direction ORDER BY ObservedCount DESC, LastSeenAt DESC) AS rn,
        CAST(ObservedCount AS DECIMAL(9,4))
            / SUM(ObservedCount) OVER (PARTITION BY AirportCode, FlightNumber, Direction) AS Confidence
    FROM stg.GateHistory
),
FlightsByLocation AS (
    -- The fan-out: every flight joined to every active location at its
    -- own airport. loc.HomeTerminalPrefix replaces what used to be a
    -- hardcoded 'A' — DTW's home prefix is 'A' (Concourse A), DFW-A8's is
    -- also 'A' (Terminal A) but DFW-B4's is 'B' (Terminal B), so the same
    -- letter can mean "home" for one location and "other terminal" for
    -- another at the same airport.
    SELECT
        f.FlightId, f.AirportCode, f.Direction, f.AirlineName, f.AirlineIataCode,
        f.FlightNumber, f.AircraftModelCode, f.Gate, f.ScheduledTime,
        f.OtherAirportCode, f.OtherAirportCity, f.DurationMinutes,
        loc.LocationId, loc.HomeTerminalPrefix
    FROM stg.Flight f
    JOIN cfg.Location loc ON loc.AirportCode = f.AirportCode AND loc.IsActive = 1
),
Parsed AS (
    SELECT
        p.*,
        COALESCE(NULLIF(p.Gate, ''), bhg.Gate) AS EffectiveGate,
        MONTH(p.ScheduledTime) AS MonthNum
    FROM FlightsByLocation p
    LEFT JOIN BestHistoricalGate bhg
        ON bhg.AirportCode = p.AirportCode AND bhg.FlightNumber = p.FlightNumber AND bhg.Direction = p.Direction
        AND bhg.rn = 1 AND bhg.Confidence >= 0.6
),
WithDaypart AS (
    SELECT
        p.*,
        -- Gate string is HomeTerminalPrefix + number (e.g. "A36", "B4")
        -- ONLY for this location's own terminal. Real schedules include
        -- gates from entirely different terminals — American, United,
        -- Frontier and others fly out of DTW's separate North Terminal;
        -- DFW's Terminal C/D/E gates are nowhere near either DFW location
        -- here. Stripping the first character and parsing blindly would
        -- read a foreign terminal's gate as if it were this location's own
        -- numbering, which is a real bug this caught at DTW (see
        -- IsOtherTerminal below) — only actually attempt the parse when
        -- the gate starts with this location's own prefix. Some real gate
        -- strings carry a trailing letter after the number too (Dulles's
        -- lower-level regional gates are "A1A".."A6A"; DFW has "B12a" and
        -- "B12b" for a split satellite gate) — stripped before casting so
        -- these still parse as their base gate number instead of failing
        -- TRY_CAST on "1A" and silently falling through to 'unknown'.
        -- PATINDEX finds the first non-digit in the substring-plus-sentinel
        -- ('X' can never itself be a false match, since it isn't a digit);
        -- LEFT(...) up to just before it keeps only the leading digits.
        CASE WHEN LEFT(p.EffectiveGate, 1) = p.HomeTerminalPrefix
             THEN TRY_CAST(
                 LEFT(
                     SUBSTRING(p.EffectiveGate, 2, 10),
                     PATINDEX('%[^0-9]%', SUBSTRING(p.EffectiveGate, 2, 10) + 'X') - 1
                 ) AS INT
             )
             ELSE NULL
        END AS GateNum,
        -- Blank ("no gate yet") and "assigned, but to a different
        -- terminal" are different facts and must resolve to different
        -- zones: the former is genuinely uncertain (see 'unknown' below),
        -- the latter is a known zero — a passenger flying out of a
        -- different terminal is never walking past this location's gate.
        CASE WHEN p.EffectiveGate <> '' AND LEFT(p.EffectiveGate, 1) <> p.HomeTerminalPrefix
             THEN 1 ELSE 0
        END AS IsOtherTerminal,
        COALESCE(
            (SELECT TOP 1 dw.Daypart FROM cfg.DaypartWindow dw
             WHERE DATEPART(HOUR, p.ScheduledTime) BETWEEN dw.StartHour AND dw.EndHour),
            'off'
        ) AS Daypart
    FROM Parsed p
),
WithZone AS (
    SELECT
        w.*,
        CASE
            WHEN w.IsOtherTerminal = 1 THEN 'other-terminal'
            ELSE COALESCE(gz.ZoneName, 'unknown')
        END AS ZoneName
    FROM WithDaypart w
    LEFT JOIN cfg.GateZoneMap gz
        ON gz.LocationId = w.LocationId AND w.GateNum BETWEEN gz.GateNumFrom AND gz.GateNumTo
),
-- Passengers doesn't depend on geometry weight (they're independent
-- factors multiplied together at the end), so it's computed here, one
-- step before AirlineGeometryPrior needs it as a weighting factor.
WithPassengers AS (
    SELECT
        z.*,
        COALESCE(seats.Seats, fallbackSeats.Seats) AS Seats,
        COALESCE(seats.AircraftModelText, fallbackSeats.AircraftModelText) AS AircraftModelText,
        -- LoadFactor = default * seasonal(month) * daypart(hour), clamped
        -- to 1.0 — a load factor above 100% isn't a real value no matter
        -- what the multipliers say, and nothing upstream guarantees they
        -- stay small enough to avoid it (today's config tops out around
        -- 0.90, but that's a fact about today's numbers, not a guarantee
        -- the formula holds). The one honest assumption in the whole
        -- model; everything upstream is a real scheduled flight,
        -- everything downstream is arithmetic on it. Shared across all
        -- locations today — a real per-airport seasonal curve (the same
        -- BTS approach already used for DTW) is the natural next step for
        -- DFW/IAD, not yet done.
        CAST(lf.EffectiveLoadFactor AS DECIMAL(5,4)) AS LoadFactor,
        CAST(COALESCE(seats.Seats, fallbackSeats.Seats) * lf.EffectiveLoadFactor AS DECIMAL(10,4)) AS Passengers
    FROM WithZone z
    -- Live schedules bring in aircraft types no hand-tuned lookup will
    -- ever fully enumerate; an unrecognized code falls back to cfg's
    -- 'UNKNOWN' row (a plausible average) rather than an INNER JOIN
    -- silently dropping the flight from the model entirely.
    LEFT JOIN cfg.SeatsByAircraftType seats ON seats.AircraftModelCode = z.AircraftModelCode
    LEFT JOIN cfg.SeatsByAircraftType fallbackSeats ON fallbackSeats.AircraftModelCode = 'UNKNOWN'
    CROSS JOIN cfg.LoadFactorDefault dflt
    LEFT JOIN cfg.LoadFactorSeasonalAdj seas ON seas.MonthNum = z.MonthNum
    LEFT JOIN cfg.LoadFactorDaypartAdj dp ON dp.Daypart = z.Daypart
    CROSS APPLY (
        SELECT LEAST(1.0, dflt.DefaultLoadFactor * COALESCE(seas.Multiplier, 1) * COALESCE(dp.Multiplier, 1)) AS EffectiveLoadFactor
    ) lf
),
-- A flat "unknown gate" weight made sense at DTW, where being unassigned
-- doesn't dilute much (one concourse structure, most competitors are
-- already a known zero via IsOtherTerminal). It falls apart at a
-- multi-terminal hub like DFW: an unassigned American Airlines flight is
-- overwhelmingly likely to be in one of AA's own terminals, but an
-- unassigned Delta flight there is overwhelmingly likely to be nowhere
-- near it — a single flat constant can't tell those two apart, and
-- checking the real numbers showed why that matters: at DFW A8, 92% of
-- what cleared the display threshold turned out to be flat-weighted
-- "unknown" guesses, not resolved gates.
--
-- The fix: derive the unknown-gate weight from that airline's *own*
-- already-resolved flights at this location instead of guessing one
-- number for everyone. An airline that's never observed away from a
-- location's home terminal gets a prior near that terminal's own weight;
-- one that's never observed IN it collapses toward zero, because
-- 'other-terminal' flights correctly contribute a real 0 to this average,
-- not just get excluded from it. Weighted by Passengers so a widebody's
-- resolved flight counts for more than a regional jet's.
AirlineGeometryPrior AS (
    SELECT
        w.LocationId,
        w.AirlineIataCode,
        SUM(COALESCE(gzw.Weight, 0) * w.Passengers) / NULLIF(SUM(w.Passengers), 0) AS PriorWeight
    FROM WithPassengers w
    LEFT JOIN cfg.GateZoneWeight gzw ON gzw.LocationId = w.LocationId AND gzw.ZoneName = w.ZoneName AND gzw.Direction = w.Direction
    WHERE w.ZoneName <> 'unknown'
    GROUP BY w.LocationId, w.AirlineIataCode
)
SELECT
    w.FlightId,
    w.LocationId,
    w.Direction,
    w.AirlineName,
    w.AirlineIataCode,
    w.FlightNumber,
    w.AircraftModelCode,
    w.AircraftModelText,
    w.Gate,
    w.ZoneName,
    w.ScheduledTime,
    w.OtherAirportCode,
    w.OtherAirportCity,
    w.DurationMinutes,
    w.Daypart,
    w.Seats,
    w.LoadFactor,
    w.Passengers,
    -- Resolved zones (home, other-terminal) use the location's own
    -- configured weight, same as always. Only 'unknown' flights fall
    -- through to the airline's empirical prior, and only fall through
    -- further to cfg's flat placeholder if that airline has no resolved
    -- flights at this location to learn a prior from at all (a brand new
    -- or extremely rare carrier here).
    COALESCE(
        CASE WHEN w.ZoneName = 'unknown' THEN prior.PriorWeight ELSE NULL END,
        gzw.Weight,
        0
    ) AS GeometryWeight,
    CAST(w.Passengers * COALESCE(
        CASE WHEN w.ZoneName = 'unknown' THEN prior.PriorWeight ELSE NULL END,
        gzw.Weight,
        0
    ) AS DECIMAL(10,4)) AS Exposure
FROM WithPassengers w
LEFT JOIN cfg.GateZoneWeight gzw ON gzw.LocationId = w.LocationId AND gzw.ZoneName = w.ZoneName AND gzw.Direction = w.Direction
LEFT JOIN AirlineGeometryPrior prior ON prior.LocationId = w.LocationId AND prior.AirlineIataCode = w.AirlineIataCode;
GO

-- ============================================================
-- mdl.FlightDwell
--   Turns each *physical flight's* dwell window into a triangular weight
--   per minute, normalized so weights sum to 1 across the window, then
--   aggregated to a per-hour DwellFraction. One row per (FlightId, hour)
--   — deliberately not per (FlightId, LocationId, hour), since dwell
--   timing never differs by which store is asking, only by the flight's
--   own scheduled time and direction. This is the discrete-event-to-
--   distributed-signal step, done set-based via cfg.Tally cross-applied
--   to each flight rather than procedurally.
-- ============================================================
CREATE OR ALTER VIEW mdl.FlightDwell AS
WITH Window AS (
    SELECT
        f.FlightId,
        f.Direction,
        dc.OffsetMinFrom,
        dc.OffsetMinTo,
        dc.PeakOffsetMin,
        (dc.OffsetMinTo - dc.OffsetMinFrom) AS WindowLengthMin,
        (dc.PeakOffsetMin - dc.OffsetMinFrom) AS PeakFromStart,
        DATEADD(MINUTE, dc.OffsetMinFrom, f.ScheduledTime) AS WindowStart
    FROM stg.Flight f
    JOIN cfg.DwellCurve dc ON dc.Direction = f.Direction
),
RawWeight AS (
    SELECT
        w.FlightId,
        t.n AS MinuteOffset,
        DATEADD(MINUTE, t.n, w.WindowStart) AS MinuteTimestamp,
        -- Triangular: rises linearly to the peak, falls linearly after.
        -- The peak minute itself is always weight 1 by definition, handled
        -- as its own case so neither leg has to divide by a PeakFromStart
        -- of exactly 0 (peak at the window's first minute). Whichever side
        -- of the peak a minute falls on is what picks rising vs. falling —
        -- a peak at or before the window start (PeakFromStart <= 0) has no
        -- rising leg at all, so every minute correctly lands in the
        -- falling branch instead of being flattened to a uniform 1.0
        -- across the whole window, which is what an earlier version of
        -- this did.
        CASE
            WHEN t.n = w.PeakFromStart THEN 1.0
            WHEN t.n < w.PeakFromStart THEN CAST(t.n AS DECIMAL(9,4)) / w.PeakFromStart
            ELSE CAST(w.WindowLengthMin - t.n AS DECIMAL(9,4)) / (w.WindowLengthMin - w.PeakFromStart)
        END AS RawWeight
    FROM Window w
    JOIN cfg.Tally t ON t.n BETWEEN 0 AND w.WindowLengthMin
),
Normalized AS (
    SELECT
        FlightId,
        MinuteTimestamp,
        RawWeight / SUM(RawWeight) OVER (PARTITION BY FlightId) AS NormalizedWeight
    FROM RawWeight
)
-- Aggregated to per-hour here (folding in what used to be the separate
-- mdl.FlightHourDwell view) — nothing downstream needs the per-minute
-- detail, only the per-hour fraction.
--
-- The triangular weight is exactly 0 at both window endpoints by
-- construction (that is what makes it a triangle), and an endpoint minute
-- occasionally lands on an hour boundary. Left unfiltered that produces a
-- phantom hour row for the flight carrying zero exposure — harmless to
-- any sum, but confusing in the drill-down, which would show a flight
-- card claiming zero passengers. Drop rows below a small epsilon rather
-- than exactly zero, since floating-point sums rarely land on exactly 0.
SELECT
    FlightId,
    CAST(MinuteTimestamp AS DATE) AS TrafficDate,
    DATEPART(HOUR, MinuteTimestamp) AS TrafficHour,
    SUM(NormalizedWeight) AS DwellFraction
FROM Normalized
GROUP BY CAST(MinuteTimestamp AS DATE), DATEPART(HOUR, MinuteTimestamp), FlightId
HAVING SUM(NormalizedWeight) > 0.0005;
GO

-- ============================================================
-- mdl.FlightHourDetail
--   Flight-level-per-hour rows, one per (flight, location, hour): the
--   drill-down's source of truth. Every field depth-3 needs to show its
--   raw math lives here already joined, so the export proc does no
--   further computation. This is where dwell timing (mdl.FlightDwell,
--   per flight) and exposure magnitude (mdl.FlightExposure, per flight
--   and location) finally come together.
-- ============================================================
CREATE OR ALTER VIEW mdl.FlightHourDetail AS
SELECT
    fd.TrafficDate,
    fd.TrafficHour,
    fe.FlightId,
    fe.LocationId,
    fe.Direction,
    fe.AirlineName,
    fe.AirlineIataCode,
    fe.FlightNumber,
    fe.AircraftModelCode,
    fe.AircraftModelText,
    fe.Gate,
    fe.ZoneName,
    fe.ScheduledTime,
    fe.OtherAirportCode,
    fe.OtherAirportCity,
    fe.DurationMinutes,
    DATEADD(MINUTE, dc.OffsetMinFrom, fe.ScheduledTime) AS WindowStartTime,
    DATEADD(MINUTE, dc.OffsetMinTo, fe.ScheduledTime) AS WindowEndTime,
    fe.Seats,
    fe.LoadFactor,
    fe.Passengers,
    fe.GeometryWeight,
    fe.Exposure,
    fd.DwellFraction,
    CAST(fe.Exposure * fd.DwellFraction AS DECIMAL(10,4)) AS ExposureAtHour
FROM mdl.FlightDwell fd
JOIN mdl.FlightExposure fe ON fe.FlightId = fd.FlightId
JOIN cfg.DwellCurve dc ON dc.Direction = fe.Direction;
GO

-- ============================================================
-- mdl.HourlyTraffic
--   The hour bar's raw exposure, before the index normalization. One row
--   per (location, date, hour).
-- ============================================================
CREATE OR ALTER VIEW mdl.HourlyTraffic AS
SELECT
    LocationId,
    TrafficDate,
    TrafficHour,
    SUM(ExposureAtHour) AS HourlyExposure
FROM mdl.FlightHourDetail
GROUP BY LocationId, TrafficDate, TrafficHour;
GO

-- ============================================================
-- mdl.HourlyIndex
--   100 = that location's own stored baseline hourly exposure
--   (cfg.IndexBaseline), not a rolling mean of the current export window
--   — see that table's comment for why.
-- ============================================================
CREATE OR ALTER VIEW mdl.HourlyIndex AS
SELECT
    ht.LocationId,
    ht.TrafficDate,
    ht.TrafficHour,
    ht.HourlyExposure,
    CAST(100.0 * ht.HourlyExposure / b.BaselineHourlyExposure AS DECIMAL(10,2)) AS TrafficIndex
FROM mdl.HourlyTraffic ht
JOIN cfg.IndexBaseline b ON b.LocationId = ht.LocationId;
GO

-- ============================================================
-- mdl.DayRollup
--   Day-level index compares the day's TOTAL exposure to that location's
--   baseline day (BaselineHourlyExposure * a fixed ReferenceOpenHours),
--   not the mean of the day's own hourly indices. Using the day's own
--   open-hour count would silently normalize away the fact that Sunday is
--   open fewer hours; comparing to a fixed reference length instead means
--   a shorter day correctly reads as lower total volume. PeakHour is the
--   single highest-exposure hour that day, for the one-per-view marker.
-- ============================================================
CREATE OR ALTER VIEW mdl.DayRollup AS
WITH DayTotal AS (
    SELECT LocationId, TrafficDate, SUM(HourlyExposure) AS TotalExposure
    FROM mdl.HourlyTraffic
    GROUP BY LocationId, TrafficDate
),
Ranked AS (
    SELECT
        LocationId,
        TrafficDate,
        TrafficHour,
        HourlyExposure,
        ROW_NUMBER() OVER (PARTITION BY LocationId, TrafficDate ORDER BY HourlyExposure DESC, TrafficHour ASC) AS rn
    FROM mdl.HourlyTraffic
)
SELECT
    dt.LocationId,
    dt.TrafficDate,
    dt.TotalExposure,
    CAST(100.0 * dt.TotalExposure / (b.BaselineHourlyExposure * b.ReferenceOpenHours) AS DECIMAL(10,2)) AS DayIndex,
    r.TrafficHour AS PeakHour
FROM DayTotal dt
JOIN cfg.IndexBaseline b ON b.LocationId = dt.LocationId
JOIN Ranked r ON r.LocationId = dt.LocationId AND r.TrafficDate = dt.TrafficDate AND r.rn = 1;
GO
