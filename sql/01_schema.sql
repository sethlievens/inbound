-- Schema layout, four layers matching the data pipeline architecture:
--   stg    raw ingest, never touched by the transform layer
--   cfg    every tunable model constant — no literals in mdl views
--   mdl    the exposure model itself (views only, no tables)
--   export the one procedure that shapes the JSON artifact
--
-- mdl (not "model") to avoid colliding in name, if not in meaning, with
-- SQL Server's own system database called model.

USE Inbound;
GO

IF SCHEMA_ID(N'stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID(N'cfg') IS NULL EXEC('CREATE SCHEMA cfg');
IF SCHEMA_ID(N'mdl') IS NULL EXEC('CREATE SCHEMA mdl');
IF SCHEMA_ID(N'export') IS NULL EXEC('CREATE SCHEMA export');
GO

-- ============================================================
-- stg — raw ingest. One row per flight-leg touching DTW.
-- Aviation Edge is called once per direction (type=departure /
-- type=arrival), so a physical flight becomes two independent
-- rows when it neither originates nor terminates at DTW — that
-- never happens here since DTW is always one endpoint, so each
-- row is exactly one leg. Shape mirrors the API 1:1 so swapping
-- the demo seed for a live pull later touches only the ingest
-- script, never anything downstream.
-- ============================================================

CREATE TABLE stg.ApiIngestBatch (
    BatchId         INT IDENTITY(1,1) PRIMARY KEY,
    RequestedDate   DATE            NOT NULL,
    Direction       VARCHAR(10)     NOT NULL,   -- 'departure' | 'arrival'
    RequestedAt     DATETIME2(0)    NOT NULL DEFAULT SYSUTCDATETIME(),
    RawResponseJson NVARCHAR(MAX)   NULL,        -- verbatim API payload, when there is one
    CONSTRAINT CK_ApiIngestBatch_Direction CHECK (Direction IN ('departure','arrival'))
);
GO

CREATE TABLE stg.Flight (
    FlightId            INT IDENTITY(1,1) PRIMARY KEY,
    BatchId             INT             NULL REFERENCES stg.ApiIngestBatch(BatchId),
    Direction           VARCHAR(10)     NOT NULL,   -- 'departure' | 'arrival', relative to DTW
    AirlineName         VARCHAR(50)     NOT NULL,
    AirlineIataCode     CHAR(2)         NOT NULL,
    FlightNumber        VARCHAR(10)     NOT NULL,
    AircraftModelCode   VARCHAR(10)     NOT NULL,   -- joins cfg.SeatsByAircraftType
    DtwGate             VARCHAR(10)     NOT NULL,
    DtwScheduledTime    DATETIME2(0)    NOT NULL,
    -- The other end of the trip — descriptive only, the model never reads
    -- these (geometry weight and exposure are driven by the DTW-side gate
    -- alone). Present because the drill-down's credibility depends on a
    -- flight reading as a real trip, not just a time and a gate.
    OtherAirportCode    CHAR(3)         NULL,
    OtherAirportCity    VARCHAR(50)     NULL,
    DurationMinutes     INT             NULL,
    CONSTRAINT CK_Flight_Direction CHECK (Direction IN ('departure','arrival'))
);
GO

CREATE INDEX IX_Flight_ScheduledTime ON stg.Flight (DtwScheduledTime);
GO

-- Live schedules this far out often haven't had a gate assigned yet (~47%
-- blank in an early sample). Rather than let a blank gate silently zero
-- out that flight's exposure (no gate -> no zone -> no weight), each
-- ingest that DOES see a real gate for a given flight number upserts a
-- count here; a later ingest for the same recurring flight number with a
-- still-blank gate can then fall back to whichever gate has actually been
-- observed most often. Empty on day one (nothing learned yet, falls
-- through to the 'unknown' zone average) and fills in as the nightly job
-- accumulates real observations — the "historical data" the gate estimate
-- is based on is our own ingest history, not a separate data source.
CREATE TABLE stg.GateHistory (
    FlightNumber    VARCHAR(10)  NOT NULL,
    Direction       VARCHAR(10)  NOT NULL,
    Gate            VARCHAR(10)  NOT NULL,
    ObservedCount   INT          NOT NULL DEFAULT 1,
    LastSeenAt      DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_GateHistory PRIMARY KEY (FlightNumber, Direction, Gate)
);
GO

-- ============================================================
-- cfg — every tunable constant. Nothing below is read as a
-- literal inside mdl; an UPDATE here changes the model, no
-- redeploy needed.
-- ============================================================

CREATE TABLE cfg.OrderCycle (
    OrderCycleDays  INT NOT NULL
);
GO

-- DayOfWeek: 0=Sunday .. 6=Saturday, independent of session DATEFIRST.
-- mdl views SET DATEFIRST 7 before computing this so the mapping holds.
CREATE TABLE cfg.OpenHours (
    DayOfWeek   TINYINT NOT NULL PRIMARY KEY,
    OpenHour    TINYINT NOT NULL,   -- store opens at the top of this hour
    CloseHour   TINYINT NOT NULL,   -- exclusive: last bar starts at CloseHour-1
    CONSTRAINT CK_OpenHours_DOW CHECK (DayOfWeek BETWEEN 0 AND 6),
    CONSTRAINT CK_OpenHours_Range CHECK (OpenHour < CloseHour)
);
GO

CREATE TABLE cfg.LoadFactorDefault (
    DefaultLoadFactor DECIMAL(4,3) NOT NULL
);
GO

CREATE TABLE cfg.LoadFactorSeasonalAdj (
    MonthNum    TINYINT      NOT NULL PRIMARY KEY,  -- 1-12
    Multiplier  DECIMAL(4,3) NOT NULL
);
GO

CREATE TABLE cfg.LoadFactorDaypartAdj (
    Daypart     VARCHAR(10)  NOT NULL PRIMARY KEY,
    Multiplier  DECIMAL(4,3) NOT NULL
);
GO

CREATE TABLE cfg.SeatsByAircraftType (
    AircraftModelCode VARCHAR(10) NOT NULL PRIMARY KEY,
    AircraftModelText VARCHAR(50) NOT NULL,
    Seats             INT         NOT NULL
);
GO

-- Gate number is parsed from the gate string (strip the 'A' prefix) at
-- query time in mdl.FlightExposure; this table buckets the numeric gate
-- into a named zone. Buckets are a v1 simplification — a distance-decay
-- function from A36 plus a tram-diversion factor would remove the
-- boundary arguments entirely, but buckets are enough to prove the shape.
CREATE TABLE cfg.GateZoneMap (
    ZoneName    VARCHAR(20) NOT NULL,
    GateNumFrom INT         NOT NULL,
    GateNumTo   INT         NOT NULL
);
GO

CREATE TABLE cfg.GateZoneWeight (
    ZoneName    VARCHAR(20)  NOT NULL,
    Direction   VARCHAR(10)  NOT NULL,  -- 'departure' | 'arrival'
    Weight      DECIMAL(4,3) NOT NULL,
    PRIMARY KEY (ZoneName, Direction)
);
GO

-- Daypart hour ranges are inclusive on both ends (breakfast 5-10 = hours 5..10).
CREATE TABLE cfg.DaypartWindow (
    Daypart     VARCHAR(10) NOT NULL PRIMARY KEY,
    StartHour   TINYINT     NOT NULL,
    EndHour     TINYINT     NOT NULL
);
GO

CREATE TABLE cfg.DwellCurve (
    Direction       VARCHAR(10) NOT NULL PRIMARY KEY,  -- 'departure' | 'arrival'
    OffsetMinFrom   INT NOT NULL,   -- minutes relative to scheduled time, e.g. -90
    OffsetMinTo     INT NOT NULL,   -- e.g. -10
    PeakOffsetMin   INT NOT NULL    -- e.g. -50
);
GO

-- The index baseline is deliberately NOT recomputed on every export run —
-- if it were the rolling-window mean, the same Friday's index would drift
-- night to night as the window rolled past it. It is refreshed on its own
-- slower schedule (see the Note column for how/when) so an index value
-- means the same thing across exports.
CREATE TABLE cfg.IndexBaseline (
    BaselineHourlyExposure DECIMAL(12,4) NOT NULL,
    ReferenceOpenHours     TINYINT       NOT NULL,  -- fixed reference day length (18, the weekday standard) used for day-level index, so a short Sunday correctly reads as lower volume rather than being normalized away
    EffectiveFrom          DATE          NOT NULL,
    Note                   NVARCHAR(200) NULL
);
GO

-- Minute-of-window numbers table, reused by the dwell allocation (0-100
-- minutes covers the longest window, the ~80-minute departure curve) and
-- by the export proc's date spine (0-13 covers the 14-day range). Sized
-- to 0-180 for headroom without meaning anything beyond "big enough".
CREATE TABLE cfg.Tally (
    n INT NOT NULL PRIMARY KEY
);
GO

-- IATA code -> city name, for the flight-detail route card. Aviation Edge
-- gives airport/city IATA codes only, never a display name.
CREATE TABLE cfg.AirportCity (
    IataCode CHAR(3)     NOT NULL PRIMARY KEY,
    City     VARCHAR(50) NOT NULL
);
GO

-- Known all-cargo/freight operators to exclude at ingest. Aviation Edge's
-- future-schedules endpoint doesn't distinguish passenger from freight
-- service, so without this a FedEx or UPS freighter reads as a passenger
-- flight and gets credited with real seats and a real load factor. Small
-- feeder/freight carriers (e.g. Suburban Air Freight) often have no IATA
-- code at all, so matching is by name OR code, whichever the ingest has.
CREATE TABLE cfg.CargoAirline (
    AirlineName VARCHAR(50) NOT NULL PRIMARY KEY,
    IataCode    VARCHAR(5)  NULL
);
GO

-- Aviation Edge's predicted schedule for Southwest at CMH is genuinely
-- sparse on Mondays and Tuesdays (confirmed repeatedly against the raw,
-- unmodified API response — not an ingest bug, a real gap in that one
-- upstream feed for that one airline/airport/day-of-week combination).
-- Southwest's own real public route list shows most CMH routes flying
-- daily, so a normal Thursday's real, already-ingested schedule (same
-- routes, gates, and times a carrier typically repeats week to week)
-- stands in as the Monday/Tuesday/Wednesday template until Aviation
-- Edge's own data improves. Applied by ingest_aviation_edge.sh after
-- every real ingest, every week, not a one-time patch.
--
-- Not seeded in 02_config_seed.sql — its rows are captured from a real
-- ingest, not hand-authored config. To (re)populate it, pick any
-- currently-healthy Thursday already in stg.Flight and run:
--   DELETE FROM cfg.SouthwestCmhTemplate;
--   INSERT INTO cfg.SouthwestCmhTemplate (FlightNumber, Direction, TimeOfDay, Gate, AircraftModelCode, OtherAirportCode, OtherAirportCity, DurationMinutes)
--   SELECT FlightNumber, Direction, CAST(ScheduledTime AS TIME), Gate, AircraftModelCode, OtherAirportCode, OtherAirportCity, DurationMinutes
--   FROM stg.Flight
--   WHERE AirportCode = 'CMH' AND AirlineName LIKE 'southwest%' AND CAST(ScheduledTime AS DATE) = '<a healthy Thursday>';
CREATE TABLE cfg.SouthwestCmhTemplate (
    TemplateId        INT IDENTITY PRIMARY KEY,
    FlightNumber      VARCHAR(10) NOT NULL,
    Direction         VARCHAR(10) NOT NULL,
    TimeOfDay         TIME        NOT NULL,
    Gate              VARCHAR(10) NOT NULL,
    AircraftModelCode VARCHAR(10) NOT NULL,
    OtherAirportCode  CHAR(3)     NULL,
    OtherAirportCity  VARCHAR(50) NULL,
    DurationMinutes   INT         NULL
);
GO

-- ============================================================
-- Real historical calibration data, from BTS (data.bts.gov's
-- Socrata mirror of the T-100 Segment table), not from the live
-- 14-day Aviation Edge window. Aviation Edge is a forward-looking
-- schedule that can't see a year back, so it can tell us today's
-- flights but not whether today is a seasonally busy or quiet
-- month — that's exactly what a 14-day snapshot can't answer and
-- BTS's monthly actuals can. This is raw ingest, untouched by the
-- transform layer, same as stg.Flight.
-- ============================================================
CREATE TABLE stg.BtsMonthlyVolume (
    AirportCode     CHAR(3)      NOT NULL,
    ReportingMonth  DATE         NOT NULL,   -- first of the month
    TotalDepartures INT          NOT NULL,
    TotalPassengers INT          NOT NULL,
    TotalSeats      INT          NOT NULL,
    TotalLoadFactor DECIMAL(5,2) NOT NULL,   -- as reported by BTS, e.g. 82.60 (percent)
    IngestedAt      DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_BtsMonthlyVolume PRIMARY KEY (AirportCode, ReportingMonth)
);
GO
