-- The exposure model. Views only, set-based throughout — no cursors, no
-- row-by-row loops. Comments explain the model the way the brief and
-- .claude/rules/sql.md explain it, since this is the piece most likely
-- to be read by whoever is hiring the SQL developer who wrote it.

USE Inbound;
GO

-- ============================================================
-- mdl.FlightExposure
--   Per flight: Exposure = (seats * loadFactor) * geometryWeight.
--   geometryWeight is looked up as a single 0-1 value per gate zone —
--   never decomposed into separate distance/probability factors, which
--   would double-count distance (see cfg.GateZoneWeight).
-- ============================================================
CREATE OR ALTER VIEW mdl.FlightExposure AS
WITH BestHistoricalGate AS (
    -- A live schedule this far out often has no gate yet (~47% blank in an
    -- early sample). Rather than let that silently zero out the flight's
    -- exposure, fall back to whichever gate that same recurring flight
    -- number has actually been seen at most often in past ingests — see
    -- stg.GateHistory. ROW_NUMBER picks the single best-observed gate per
    -- flight number/direction so the join below can't fan out multiple rows.
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
        FlightNumber, Direction, Gate,
        ROW_NUMBER() OVER (PARTITION BY FlightNumber, Direction ORDER BY ObservedCount DESC, LastSeenAt DESC) AS rn,
        CAST(ObservedCount AS DECIMAL(9,4))
            / SUM(ObservedCount) OVER (PARTITION BY FlightNumber, Direction) AS Confidence
    FROM stg.GateHistory
),
Parsed AS (
    SELECT
        f.FlightId,
        f.Direction,
        f.AirlineName,
        f.AirlineIataCode,
        f.FlightNumber,
        f.AircraftModelCode,
        f.DtwGate,
        COALESCE(NULLIF(f.DtwGate, ''), bhg.Gate) AS EffectiveGate,
        f.DtwScheduledTime,
        f.OtherAirportCode,
        f.OtherAirportCity,
        f.DurationMinutes,
        MONTH(f.DtwScheduledTime) AS MonthNum
    FROM stg.Flight f
    LEFT JOIN BestHistoricalGate bhg
        ON bhg.FlightNumber = f.FlightNumber AND bhg.Direction = f.Direction
        AND bhg.rn = 1 AND bhg.Confidence >= 0.6
),
WithDaypart AS (
    SELECT
        p.*,
        -- Gate string is "A" + number (e.g. "A36") ONLY for Concourse A.
        -- Real DTW schedules include gates like "D31" or "B12" — American,
        -- United, Frontier, and others fly out of a separate terminal
        -- entirely (not walking distance to A36 at all). Stripping the
        -- first character and parsing blindly would read "D31" as gate 31
        -- and bucket it into Concourse A's own center zone, which is a
        -- real bug this caught: only actually attempt the parse when the
        -- gate starts with "A".
        CASE WHEN LEFT(p.EffectiveGate, 1) = 'A'
             THEN TRY_CAST(SUBSTRING(p.EffectiveGate, 2, 10) AS INT)
             ELSE NULL
        END AS GateNum,
        -- Blank ("no gate yet") and "assigned, but to a different
        -- terminal" are different facts and must resolve to different
        -- zones: the former is genuinely uncertain (see 'unknown' below),
        -- the latter is a known zero — a passenger flying out of the
        -- North Terminal is never walking past A36.
        CASE WHEN p.EffectiveGate <> '' AND LEFT(p.EffectiveGate, 1) <> 'A'
             THEN 1 ELSE 0
        END AS IsOtherTerminal,
        COALESCE(
            (SELECT TOP 1 dw.Daypart FROM cfg.DaypartWindow dw
             WHERE DATEPART(HOUR, p.DtwScheduledTime) BETWEEN dw.StartHour AND dw.EndHour),
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
        ON w.GateNum BETWEEN gz.GateNumFrom AND gz.GateNumTo
)
SELECT
    z.FlightId,
    z.Direction,
    z.AirlineName,
    z.AirlineIataCode,
    z.FlightNumber,
    z.AircraftModelCode,
    COALESCE(seats.AircraftModelText, fallbackSeats.AircraftModelText) AS AircraftModelText,
    z.DtwGate,
    z.ZoneName,
    z.DtwScheduledTime,
    z.OtherAirportCode,
    z.OtherAirportCity,
    z.DurationMinutes,
    z.Daypart,
    COALESCE(seats.Seats, fallbackSeats.Seats) AS Seats,
    -- LoadFactor = default * seasonal(month) * daypart(hour), clamped to
    -- 1.0 — a load factor above 100% isn't a real value no matter what the
    -- multipliers say, and nothing upstream guarantees they stay small
    -- enough to avoid it (today's config tops out around 0.90, but that's
    -- a fact about today's numbers, not a guarantee the formula holds).
    -- The one honest assumption in the whole model; everything upstream is
    -- a real scheduled flight, everything downstream is arithmetic on it.
    CAST(lf.EffectiveLoadFactor AS DECIMAL(5,4)) AS LoadFactor,
    CAST(COALESCE(seats.Seats, fallbackSeats.Seats) * lf.EffectiveLoadFactor AS DECIMAL(10,4)) AS Passengers,
    COALESCE(gzw.Weight, 0) AS GeometryWeight,
    CAST(COALESCE(seats.Seats, fallbackSeats.Seats) * lf.EffectiveLoadFactor
         * COALESCE(gzw.Weight, 0) AS DECIMAL(10,4)) AS Exposure,
    -- The dwell window as real timestamps, not just offsets — surfaced so
    -- the drill-down can show "when this flight's passengers are actually
    -- moving through the concourse" (the "impact window"), the same
    -- window mdl.FlightMinuteWeight expands minute-by-minute below.
    DATEADD(MINUTE, dc.OffsetMinFrom, z.DtwScheduledTime) AS WindowStartTime,
    DATEADD(MINUTE, dc.OffsetMinTo, z.DtwScheduledTime) AS WindowEndTime
FROM WithZone z
-- Live schedules bring in aircraft types no hand-tuned lookup will ever
-- fully enumerate; an unrecognized code falls back to cfg's 'UNKNOWN' row
-- (a plausible average) rather than an INNER JOIN silently dropping the
-- flight from the model entirely.
LEFT JOIN cfg.SeatsByAircraftType seats ON seats.AircraftModelCode = z.AircraftModelCode
LEFT JOIN cfg.SeatsByAircraftType fallbackSeats ON fallbackSeats.AircraftModelCode = 'UNKNOWN'
JOIN cfg.DwellCurve dc ON dc.Direction = z.Direction
CROSS JOIN cfg.LoadFactorDefault dflt
LEFT JOIN cfg.LoadFactorSeasonalAdj seas ON seas.MonthNum = z.MonthNum
LEFT JOIN cfg.LoadFactorDaypartAdj dp ON dp.Daypart = z.Daypart
LEFT JOIN cfg.GateZoneWeight gzw ON gzw.ZoneName = z.ZoneName AND gzw.Direction = z.Direction
CROSS APPLY (
    SELECT LEAST(1.0, dflt.DefaultLoadFactor * COALESCE(seas.Multiplier, 1) * COALESCE(dp.Multiplier, 1)) AS EffectiveLoadFactor
) lf;
GO

-- ============================================================
-- mdl.FlightMinuteWeight
--   Turns each flight's dwell window into a triangular weight per
--   minute, normalized so weights sum to 1 across the window. This is
--   the discrete-event-to-distributed-signal step, done set-based via
--   cfg.Tally cross-applied to each flight rather than procedurally.
-- ============================================================
CREATE OR ALTER VIEW mdl.FlightMinuteWeight AS
WITH Window AS (
    SELECT
        fe.FlightId,
        fe.Direction,
        dc.OffsetMinFrom,
        dc.OffsetMinTo,
        dc.PeakOffsetMin,
        (dc.OffsetMinTo - dc.OffsetMinFrom) AS WindowLengthMin,
        (dc.PeakOffsetMin - dc.OffsetMinFrom) AS PeakFromStart,
        DATEADD(MINUTE, dc.OffsetMinFrom, fe.DtwScheduledTime) AS WindowStart
    FROM mdl.FlightExposure fe
    JOIN cfg.DwellCurve dc ON dc.Direction = fe.Direction
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
)
SELECT
    FlightId,
    MinuteTimestamp,
    RawWeight,
    RawWeight / SUM(RawWeight) OVER (PARTITION BY FlightId) AS NormalizedWeight
FROM RawWeight;
GO

-- ============================================================
-- mdl.FlightHourDwell
--   Aggregates per-minute weight into per-hour dwellFraction. Fractions
--   sum to 1 across a flight's active hours because the minute weights
--   they are built from already sum to 1 across the window.
--
--   The triangular weight is exactly 0 at both window endpoints by
--   construction (that is what makes it a triangle), and an endpoint
--   minute occasionally lands on an hour boundary. Left unfiltered that
--   produces a phantom hour row for the flight carrying zero exposure —
--   harmless to any sum, but confusing in the drill-down, which would
--   show a flight card claiming zero passengers past A36. Drop rows
--   below a small epsilon rather than exactly zero, since floating-point
--   sums rarely land on exactly 0.
-- ============================================================
CREATE OR ALTER VIEW mdl.FlightHourDwell AS
SELECT
    fmw.FlightId,
    CAST(fmw.MinuteTimestamp AS DATE) AS TrafficDate,
    DATEPART(HOUR, fmw.MinuteTimestamp) AS TrafficHour,
    SUM(fmw.NormalizedWeight) AS DwellFraction
FROM mdl.FlightMinuteWeight fmw
GROUP BY CAST(fmw.MinuteTimestamp AS DATE), DATEPART(HOUR, fmw.MinuteTimestamp), fmw.FlightId
HAVING SUM(fmw.NormalizedWeight) > 0.0005;
GO

-- ============================================================
-- mdl.FlightHourDetail
--   Flight-level-per-hour rows: the drill-down's source of truth. Every
--   field depth-3 needs to show its raw math lives here already joined,
--   so the export proc does no further computation.
-- ============================================================
CREATE OR ALTER VIEW mdl.FlightHourDetail AS
SELECT
    fhd.TrafficDate,
    fhd.TrafficHour,
    fe.FlightId,
    fe.Direction,
    fe.AirlineName,
    fe.AirlineIataCode,
    fe.FlightNumber,
    fe.AircraftModelCode,
    fe.AircraftModelText,
    fe.DtwGate,
    fe.ZoneName,
    fe.DtwScheduledTime,
    fe.OtherAirportCode,
    fe.OtherAirportCity,
    fe.DurationMinutes,
    fe.WindowStartTime,
    fe.WindowEndTime,
    fe.Seats,
    fe.LoadFactor,
    fe.Passengers,
    fe.GeometryWeight,
    fe.Exposure,
    fhd.DwellFraction,
    CAST(fe.Exposure * fhd.DwellFraction AS DECIMAL(10,4)) AS ExposureAtHour
FROM mdl.FlightHourDwell fhd
JOIN mdl.FlightExposure fe ON fe.FlightId = fhd.FlightId;
GO

-- ============================================================
-- mdl.HourlyTraffic
--   The hour bar's raw exposure, before the index normalization.
-- ============================================================
CREATE OR ALTER VIEW mdl.HourlyTraffic AS
SELECT
    TrafficDate,
    TrafficHour,
    SUM(ExposureAtHour) AS HourlyExposure
FROM mdl.FlightHourDetail
GROUP BY TrafficDate, TrafficHour;
GO

-- ============================================================
-- mdl.HourlyIndex
--   100 = the stored baseline hourly exposure (cfg.IndexBaseline), not
--   a rolling mean of the current export window — see that table's
--   comment for why.
-- ============================================================
CREATE OR ALTER VIEW mdl.HourlyIndex AS
SELECT
    ht.TrafficDate,
    ht.TrafficHour,
    ht.HourlyExposure,
    CAST(100.0 * ht.HourlyExposure / b.BaselineHourlyExposure AS DECIMAL(10,2)) AS TrafficIndex
FROM mdl.HourlyTraffic ht
CROSS JOIN cfg.IndexBaseline b;
GO

-- ============================================================
-- mdl.DayRollup
--   Day-level index compares the day's TOTAL exposure to the baseline
--   day (BaselineHourlyExposure * a fixed ReferenceOpenHours), not the
--   mean of the day's own hourly indices. Using the day's own open-hour
--   count would silently normalize away the fact that Sunday is open
--   fewer hours; comparing to a fixed reference length instead means a
--   shorter day correctly reads as lower total volume. PeakHour is the
--   single highest-exposure hour that day, for the one-per-view marker.
-- ============================================================
CREATE OR ALTER VIEW mdl.DayRollup AS
WITH DayTotal AS (
    SELECT TrafficDate, SUM(HourlyExposure) AS TotalExposure
    FROM mdl.HourlyTraffic
    GROUP BY TrafficDate
),
Ranked AS (
    SELECT
        TrafficDate,
        TrafficHour,
        HourlyExposure,
        ROW_NUMBER() OVER (PARTITION BY TrafficDate ORDER BY HourlyExposure DESC, TrafficHour ASC) AS rn
    FROM mdl.HourlyTraffic
)
SELECT
    dt.TrafficDate,
    dt.TotalExposure,
    CAST(100.0 * dt.TotalExposure / (b.BaselineHourlyExposure * b.ReferenceOpenHours) AS DECIMAL(10,2)) AS DayIndex,
    r.TrafficHour AS PeakHour
FROM DayTotal dt
CROSS JOIN cfg.IndexBaseline b
JOIN Ranked r ON r.TrafficDate = dt.TrafficDate AND r.rn = 1;
GO
