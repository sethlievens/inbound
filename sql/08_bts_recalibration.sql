-- Recalibrates the model's two guessed constants against real BTS data
-- instead of hand-tuned priors:
--
--   cfg.LoadFactorDefault / cfg.LoadFactorSeasonalAdj — was a single flat
--   0.83 with a hand-tuned +/-6% monthly nudge. Real DTW load factor
--   swings much more than that (BTS shows 71.1% in a slow January to
--   82.6% in peak July), so the seasonal multiplier was quietly
--   understating winter softness and summer strength. Still shared across
--   every location today (calibrated from DTW's BTS data specifically,
--   not blended with DFW's) — a real per-airport seasonal curve is the
--   natural next step once each location has earned its own calibration,
--   not done yet.
--
--   cfg.IndexBaseline — was calibrated from whatever 14-day Aviation Edge
--   window happened to be live, which by construction can only ever
--   reflect "average of the next two weeks," not "average of a year."
--   Worse, that window usually sits at a random point in the season, so a
--   baseline calibrated from a peak-season window (like late July, when
--   this was first built) makes every peak-season day read as merely
--   "average" — exactly backwards from what the range view needs for a
--   real ordering decision. This one IS computed per location, since each
--   location's own airport has its own real volume and each location's
--   own gate weights the traffic differently.
--
-- Run this after ./scripts/ingest_bts_monthly.sh has populated
-- stg.BtsMonthlyVolume for every active location's airport, and after
-- there's a live-ingested stg.Flight window to compute today's gate mix
-- from. Re-running is safe; every UPDATE recomputes from the current
-- contents of both tables.
--
-- Aviation Edge is a forward-looking schedule; it can't see a year back to
-- tell us whether "now" is seasonally busy or quiet. BTS's monthly actuals
-- can, but have no gate data. The split below uses each source for the
-- one thing it actually knows: BTS for total per-airport volume and its
-- real seasonal shape, the live pipeline for what fraction of that volume
-- is estimated to walk past each specific location's gate (gate mix
-- doesn't move on a seasonal clock the way passenger volume does, so a
-- couple of live-ingested weeks is a reasonable stand-in for "typical"
-- gate mix in a way it never could be for typical *volume*).

USE Inbound;
GO

-- ============================================================
-- Load factor: replace the single flat default and the hand-tuned
-- monthly multiplier with real BTS-measured values, from DTW specifically
-- (see header). DefaultLoadFactor becomes DTW's trailing-12-month
-- average; each month's multiplier is that month's measured load factor
-- divided by the same average, so DefaultLoadFactor * Multiplier
-- reproduces DTW's real measured value for that month exactly.
-- ============================================================
DECLARE @AvgLoadFactor DECIMAL(6,4) = (
    SELECT AVG(TotalLoadFactor) / 100.0 FROM stg.BtsMonthlyVolume WHERE AirportCode = 'DTW'
);

UPDATE cfg.LoadFactorDefault SET DefaultLoadFactor = @AvgLoadFactor;

UPDATE adj
SET adj.Multiplier = CAST((bts.TotalLoadFactor / 100.0) / @AvgLoadFactor AS DECIMAL(4,3))
FROM cfg.LoadFactorSeasonalAdj adj
JOIN stg.BtsMonthlyVolume bts ON MONTH(bts.ReportingMonth) = adj.MonthNum AND bts.AirportCode = 'DTW';

-- ============================================================
-- Index baseline, per location: BaselineHourlyExposure = (real annual
-- average hourly passenger volume through that location's airport, from
-- BTS) x (that location's own live-observed, passenger-weighted average
-- geometry weight, from mdl.FlightExposure). One UPDATE, set-based,
-- covering every active location at once rather than a per-location loop.
--
-- Open-hours-per-day is a flat average across each location's own 7
-- day-of-week rows in cfg.OpenHours, not a per-month calendar count of how
-- many Sundays that month actually had — the difference between months is
-- at most a day's worth of hours, well inside the rest of this
-- calibration's own margin of error, so computing it exactly wouldn't buy
-- back any real precision.
-- ============================================================
;WITH AvgOpenHours AS (
    SELECT LocationId, AVG(CAST(CloseHour - OpenHour AS DECIMAL(6,4))) AS AvgOpenHoursPerDay
    FROM cfg.OpenHours
    GROUP BY LocationId
),
AnnualVolume AS (
    SELECT AirportCode, AVG(CAST(TotalPassengers AS DECIMAL(14,2))) AS AvgMonthlyPassengers
    FROM stg.BtsMonthlyVolume
    GROUP BY AirportCode
),
LiveGeometryWeight AS (
    SELECT LocationId, SUM(GeometryWeight * Passengers) / SUM(Passengers) AS AvgGeometryWeight
    FROM mdl.FlightExposure
    GROUP BY LocationId
),
Calibrated AS (
    SELECT
        loc.LocationId,
        av.AvgMonthlyPassengers / (365.25 / 12) / oh.AvgOpenHoursPerDay AS AnnualAvgHourlyPassengers,
        gw.AvgGeometryWeight
    FROM cfg.Location loc
    JOIN AvgOpenHours oh ON oh.LocationId = loc.LocationId
    JOIN AnnualVolume av ON av.AirportCode = loc.AirportCode
    JOIN LiveGeometryWeight gw ON gw.LocationId = loc.LocationId
    WHERE loc.IsActive = 1
)
UPDATE b
SET b.BaselineHourlyExposure = CAST(c.AnnualAvgHourlyPassengers * c.AvgGeometryWeight AS DECIMAL(12,4)),
    b.EffectiveFrom = CAST(SYSUTCDATETIME() AS DATE),
    b.Note = CONCAT(
        'BTS 12-mo avg hourly pax ', CAST(ROUND(c.AnnualAvgHourlyPassengers, 1) AS VARCHAR(20)),
        ' x live geometry weight ', CAST(c.AvgGeometryWeight AS VARCHAR(10))
    )
FROM cfg.IndexBaseline b
JOIN Calibrated c ON c.LocationId = b.LocationId;

SELECT * FROM cfg.LoadFactorDefault;
SELECT * FROM cfg.LoadFactorSeasonalAdj ORDER BY MonthNum;
SELECT loc.DisplayName, b.* FROM cfg.IndexBaseline b JOIN cfg.Location loc ON loc.LocationId = b.LocationId ORDER BY b.LocationId;
GO
