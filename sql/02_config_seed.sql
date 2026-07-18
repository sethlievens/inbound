-- Seeds every cfg table with v1 defaults. Idempotent: safe to re-run,
-- each block clears its own table first rather than assuming empty state.

USE Inbound;
GO

TRUNCATE TABLE cfg.Tally;
INSERT INTO cfg.Tally (n)
SELECT TOP (181) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
GO

TRUNCATE TABLE cfg.OrderCycle;
INSERT INTO cfg.OrderCycle (OrderCycleDays) VALUES (7);
GO

TRUNCATE TABLE cfg.OpenHours;
INSERT INTO cfg.OpenHours (DayOfWeek, OpenHour, CloseHour) VALUES
    (0, 6, 22),  -- Sunday: 6am-10pm, 16 bars
    (1, 5, 23),  -- Monday: 5am-11pm, 18 bars
    (2, 5, 23),
    (3, 5, 23),
    (4, 5, 23),
    (5, 5, 23),
    (6, 5, 23);  -- Saturday
GO

TRUNCATE TABLE cfg.LoadFactorDefault;
INSERT INTO cfg.LoadFactorDefault (DefaultLoadFactor) VALUES (0.830);
GO

-- Light seasonal lift into peak summer travel, tapering shoulder/winter.
-- Priors, not measured — tunable without touching the model.
TRUNCATE TABLE cfg.LoadFactorSeasonalAdj;
INSERT INTO cfg.LoadFactorSeasonalAdj (MonthNum, Multiplier) VALUES
    (1, 0.94), (2, 0.95), (3, 0.98), (4, 0.99), (5, 1.01), (6, 1.04),
    (7, 1.06), (8, 1.05), (9, 0.99), (10, 0.98), (11, 1.00), (12, 1.03);
GO

TRUNCATE TABLE cfg.LoadFactorDaypartAdj;
INSERT INTO cfg.LoadFactorDaypartAdj (Daypart, Multiplier) VALUES
    ('breakfast', 1.00),
    ('lunch',     0.97),
    ('dinner',    1.02),
    ('off',       0.93);
GO

-- Hand-tuned demo types (first block) plus every code actually observed
-- from a live Aviation Edge pull at DTW (second block) — real schedules
-- bring in far more variety (regional jets through widebodies) than the
-- hand-tuned dataset alone. 'UNKNOWN' is the fallback for any code neither
-- covers, so an unrecognized aircraft type degrades to a plausible
-- average rather than silently dropping the flight (see mdl.FlightExposure).
TRUNCATE TABLE cfg.SeatsByAircraftType;
INSERT INTO cfg.SeatsByAircraftType (AircraftModelCode, AircraftModelText, Seats) VALUES
    ('CRJ9', 'Bombardier CRJ-900',      76),
    ('E175', 'Embraer E175',            76),
    ('B717', 'Boeing 717-200',         110),
    ('A319', 'Airbus A319',            128),
    ('A320', 'Airbus A320',            160),
    ('A321', 'Airbus A321',            190),
    ('B757', 'Boeing 757-200',         199),
    ('A330', 'Airbus A330-900neo',     281),
    ('B763', 'Boeing 767-300ER',       216),
    -- observed live codes (Aviation Edge's own modelCode, uppercased)
    ('A20N', 'Airbus A320neo',         150),
    ('A21N', 'Airbus A321neo',         196),
    ('A306', 'Airbus A300-600',        266),
    ('A332', 'Airbus A330-200',        253),
    ('A333', 'Airbus A330-300',        277),
    ('A339', 'Airbus A330-900neo',     281),
    ('A343', 'Airbus A340-300',        295),
    ('A359', 'Airbus A350-900',        306),
    ('B38M', 'Boeing 737 MAX 8',       172),
    ('B39M', 'Boeing 737 MAX 9',       178),
    ('B712', 'Boeing 717-200',         110),
    ('B738', 'Boeing 737-800',         160),
    ('B739', 'Boeing 737-900',         178),
    ('B752', 'Boeing 757-200',         199),
    ('B753', 'Boeing 757-300',         234),
    ('B772', 'Boeing 777-200',         291),
    ('B788', 'Boeing 787-8',           234),
    ('B789', 'Boeing 787-9',           290),
    ('BCS3', 'Airbus A220-300',        130),
    ('CRJ7', 'Bombardier CRJ-700',      65),
    ('E145', 'Embraer ERJ-145',         50),
    ('E170', 'Embraer E170',            72),
    ('E190', 'Embraer E190',            97),
    ('E75L', 'Embraer E175',            76),
    ('E75S', 'Embraer E175 (short)',    76),
    ('B737', 'Boeing 737 (generic/unspecified variant)', 140),
    ('UNKNOWN', 'Unrecognized aircraft type (fallback)', 150);
GO

-- A36 sits in the central funnel (Terminal tram zone, A29-A55). South and
-- center gates feed walkers past it; far-north gates divert north or take
-- the tram from Terminal station, skipping the store. A46-55 is the same
-- tram zone as A36 and stays close to the central-zone weight rather than
-- fading toward the far-north band. 'unknown' isn't a gate range — it's
-- what a flight resolves to when Aviation Edge hasn't assigned a gate yet
-- and stg.GateHistory has no observation for that flight number either.
TRUNCATE TABLE cfg.GateZoneMap;
INSERT INTO cfg.GateZoneMap (ZoneName, GateNumFrom, GateNumTo) VALUES
    ('south',         1, 20),
    ('center',       21, 45),
    ('terminal-tram', 46, 55),
    ('far-north',     56, 78);
GO

-- Arrivals funnel back through the center toward baggage/ground transport
-- or connecting gates, so arrival weights run close to departure weights
-- rather than lower — DTW is a Delta hub and a large share of traffic is
-- connecting (gate to gate through the center), which this table does not
-- ignore. 'unknown' sits at a middling weight — an honest "we don't know
-- yet" average rather than the 0 a missing zone match would otherwise
-- collapse to, which would silently understate real foot traffic given
-- how often gates aren't assigned this far out (see sql.md's note on
-- cfg.GateZoneWeight for the reasoning).
TRUNCATE TABLE cfg.GateZoneWeight;
INSERT INTO cfg.GateZoneWeight (ZoneName, Direction, Weight) VALUES
    ('south',         'departure', 0.65), ('south',         'arrival', 0.68),
    ('center',        'departure', 0.85), ('center',        'arrival', 0.85),
    ('terminal-tram', 'departure', 0.60), ('terminal-tram', 'arrival', 0.62),
    ('far-north',     'departure', 0.20), ('far-north',     'arrival', 0.25),
    ('unknown',       'departure', 0.55), ('unknown',       'arrival', 0.58);
GO

TRUNCATE TABLE cfg.DaypartWindow;
INSERT INTO cfg.DaypartWindow (Daypart, StartHour, EndHour) VALUES
    ('breakfast',  5, 10),
    ('lunch',     11, 14),
    ('dinner',    16, 20);
    -- 'off' is everything not covered above; computed in mdl, not stored.
GO

TRUNCATE TABLE cfg.DwellCurve;
INSERT INTO cfg.DwellCurve (Direction, OffsetMinFrom, OffsetMinTo, PeakOffsetMin) VALUES
    ('departure', -90, -10, -50),
    ('arrival',     0,  20,   5);
GO

-- Placeholder baseline — 1.0 is not a real average, it exists only so the
-- database is queryable before a real one is calibrated. ReferenceOpenHours
-- =18 matches the weekday-standard day length, so Sunday's shorter day
-- reads as lower total volume rather than being normalized away.
--
-- WARNING: re-running this script against a database that already has a
-- calibrated baseline resets it back to this placeholder (TRUNCATE, same
-- as every other table here) — and because HourlyIndex/DayRollup divide by
-- it directly, every index value on the site instantly goes from ~100 to
-- five/six digits. This happened once. Recalibrate immediately after
-- reseeding, before generating another export, with:
--
--   ;WITH OpenHourTraffic AS (
--       SELECT ht.HourlyExposure FROM mdl.HourlyTraffic ht
--       JOIN cfg.OpenHours oh ON oh.DayOfWeek = DATEPART(WEEKDAY, ht.TrafficDate) - 1
--           AND ht.TrafficHour BETWEEN oh.OpenHour AND oh.CloseHour - 1
--   )
--   UPDATE cfg.IndexBaseline SET BaselineHourlyExposure = (SELECT AVG(HourlyExposure) FROM OpenHourTraffic);
--
-- (SET DATEFIRST 7 first, so the DayOfWeek join lines up with cfg.OpenHours'
-- 0=Sunday convention.) Run it against whatever's currently in stg.Flight —
-- make sure that's the real live window and not stale rows from a prior
-- demo seed, which will skew the average.
TRUNCATE TABLE cfg.IndexBaseline;
INSERT INTO cfg.IndexBaseline (BaselineHourlyExposure, ReferenceOpenHours, EffectiveFrom, Note) VALUES
    (1.0, 18, '2026-07-18', 'placeholder — recalibrate from mdl.HourlyTraffic before exporting, see comment above');
GO

-- City names for the flight-detail route card. Aviation Edge gives IATA
-- codes only; anything not in this list falls back to showing the bare
-- code rather than a missing/blank city (see the export proc's join).
TRUNCATE TABLE cfg.AirportCity;
INSERT INTO cfg.AirportCity (IataCode, City) VALUES
    ('ATL', 'Atlanta'),
    ('MSP', 'Minneapolis'),
    ('JFK', 'New York'),
    ('LGA', 'New York'),
    ('EWR', 'Newark'),
    ('BOS', 'Boston'),
    ('DCA', 'Washington'),
    ('IAD', 'Washington'),
    ('BWI', 'Baltimore'),
    ('PHL', 'Philadelphia'),
    ('RDU', 'Raleigh/Durham'),
    ('CLT', 'Charlotte'),
    ('MCO', 'Orlando'),
    ('FLL', 'Fort Lauderdale'),
    ('TPA', 'Tampa'),
    ('MIA', 'Miami'),
    ('JAX', 'Jacksonville'),
    ('SAV', 'Savannah'),
    ('CHS', 'Charleston'),
    ('RSW', 'Fort Myers'),
    ('PBI', 'West Palm Beach'),
    ('ORD', 'Chicago'),
    ('MDW', 'Chicago'),
    ('STL', 'St. Louis'),
    ('MCI', 'Kansas City'),
    ('IND', 'Indianapolis'),
    ('CMH', 'Columbus'),
    ('CVG', 'Cincinnati'),
    ('CLE', 'Cleveland'),
    ('PIT', 'Pittsburgh'),
    ('BUF', 'Buffalo'),
    ('ROC', 'Rochester'),
    ('SYR', 'Syracuse'),
    ('MKE', 'Milwaukee'),
    ('DTW', 'Detroit'),
    ('GRR', 'Grand Rapids'),
    ('TOL', 'Toledo'),
    ('DAY', 'Dayton'),
    ('SDF', 'Louisville'),
    ('BNA', 'Nashville'),
    ('MEM', 'Memphis'),
    ('XNA', 'Northwest Arkansas'),
    ('LIT', 'Little Rock'),
    ('MSY', 'New Orleans'),
    ('BHM', 'Birmingham'),
    ('HSV', 'Huntsville'),
    ('GSP', 'Greenville/Spartanburg'),
    ('GSO', 'Greensboro'),
    ('RIC', 'Richmond'),
    ('ORF', 'Norfolk'),
    ('DEN', 'Denver'),
    ('SLC', 'Salt Lake City'),
    ('PHX', 'Phoenix'),
    ('TUS', 'Tucson'),
    ('ABQ', 'Albuquerque'),
    ('LAS', 'Las Vegas'),
    ('SAN', 'San Diego'),
    ('LAX', 'Los Angeles'),
    ('SFO', 'San Francisco'),
    ('OAK', 'Oakland'),
    ('SJC', 'San Jose'),
    ('SEA', 'Seattle'),
    ('PDX', 'Portland'),
    ('BOI', 'Boise'),
    ('SAT', 'San Antonio'),
    ('AUS', 'Austin'),
    ('DFW', 'Dallas'),
    ('IAH', 'Houston'),
    ('HOU', 'Houston'),
    ('OKC', 'Oklahoma City'),
    ('TUL', 'Tulsa'),
    ('ICT', 'Wichita'),
    ('OMA', 'Omaha'),
    ('DSM', 'Des Moines'),
    ('MSN', 'Madison'),
    ('GRB', 'Green Bay'),
    ('FAR', 'Fargo'),
    ('FSD', 'Sioux Falls'),
    ('SGF', 'Springfield'),
    ('TYS', 'Knoxville'),
    ('CHA', 'Chattanooga'),
    ('AVL', 'Asheville'),
    ('ILM', 'Wilmington'),
    ('MYR', 'Myrtle Beach'),
    ('ECP', 'Panama City'),
    ('VPS', 'Destin/Fort Walton Beach'),
    ('PNS', 'Pensacola'),
    ('TLH', 'Tallahassee'),
    ('GNV', 'Gainesville'),
    ('AMS', 'Amsterdam'),
    ('CDG', 'Paris'),
    ('LHR', 'London'),
    ('FCO', 'Rome'),
    ('MAD', 'Madrid'),
    ('BCN', 'Barcelona'),
    ('MUC', 'Munich'),
    ('FRA', 'Frankfurt'),
    ('DUB', 'Dublin'),
    ('KEF', 'Reykjavik'),
    ('YYZ', 'Toronto'),
    ('YUL', 'Montreal'),
    ('YYC', 'Calgary'),
    ('YVR', 'Vancouver'),
    ('CUN', 'Cancun'),
    ('PUJ', 'Punta Cana'),
    ('SJU', 'San Juan'),
    ('NAS', 'Nassau'),
    ('MBJ', 'Montego Bay'),
    ('PTY', 'Panama City'),
    -- Added after a live-data audit turned up these codes on real flights
    -- (regional airports, and international routes wider than the original
    -- hand-picked list anticipated).
    ('ALB', 'Albany'),
    ('AMM', 'Amman'),
    ('ANC', 'Anchorage'),
    ('APN', 'Alpena'),
    ('ATW', 'Appleton'),
    ('AZO', 'Kalamazoo'),
    ('BDL', 'Hartford'),
    ('BGM', 'Binghamton'),
    ('BTV', 'Burlington'),
    ('CIU', 'Sault Ste. Marie'),
    ('ELM', 'Elmira'),
    ('ESC', 'Escanaba'),
    ('FWA', 'Fort Wayne'),
    ('HND', 'Tokyo'),
    ('HNL', 'Honolulu'),
    ('HPN', 'White Plains'),
    ('HVN', 'New Haven'),
    ('ICN', 'Seoul'),
    ('IMT', 'Iron Mountain'),
    ('IST', 'Istanbul'),
    ('LEX', 'Lexington'),
    ('MBS', 'Saginaw'),
    ('MDT', 'Harrisburg'),
    ('MEX', 'Mexico City'),
    ('MQT', 'Marquette'),
    ('MTY', 'Monterrey'),
    ('PLN', 'Pellston'),
    ('PVG', 'Shanghai'),
    ('PWM', 'Portland'),
    ('QRO', 'Queretaro'),
    ('SBN', 'South Bend'),
    ('SNA', 'Santa Ana'),
    ('TVC', 'Traverse City'),
    ('YHZ', 'Halifax');
GO

-- All-cargo operators seen at DTW (or plausible there) to exclude at
-- ingest — see cfg.CargoAirline's schema comment. Matched by IataCode when
-- the carrier has one; small feeder freight operators mostly don't, so
-- those rely on an exact name match instead.
TRUNCATE TABLE cfg.CargoAirline;
INSERT INTO cfg.CargoAirline (AirlineName, IataCode) VALUES
    ('fedex',                    'FX'),
    ('fedex express',            'FX'),
    ('ups',                      '5X'),
    ('ups airlines',             '5X'),
    ('atlas air',                '5Y'),
    ('kalitta air',              'K4'),
    ('abx air',                  'GB'),
    ('amerijet international',   'M6'),
    ('suburban air freight',     NULL),
    ('mountain air cargo',       NULL),
    ('empire airlines',          NULL),
    ('baron aviation services',  NULL),
    ('csa air',                  NULL),
    ('wiggins airways',          NULL),
    ('berry aviation',           NULL);
GO
