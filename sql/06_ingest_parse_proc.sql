-- Turns one landed Aviation Edge response (stg.ApiIngestBatch.RawResponseJson,
-- untouched) into structured stg.Flight rows. Set-based via OPENJSON — no
-- cursors, no row-by-row loop over the response array.

USE Inbound;
GO

CREATE OR ALTER PROCEDURE stg.usp_ParseAviationEdgeBatch
    @BatchId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Direction VARCHAR(10), @RequestedDate DATE, @AirportCode CHAR(3), @RawJson NVARCHAR(MAX);
    SELECT @Direction = Direction, @RequestedDate = RequestedDate, @AirportCode = AirportCode, @RawJson = RawResponseJson
    FROM stg.ApiIngestBatch
    WHERE BatchId = @BatchId;

    -- Direction picks which side of the payload is @AirportCode's own leg:
    -- for a departure query @AirportCode is always "departure.*"; for an
    -- arrival query it's always "arrival.*". The other side is always the
    -- other airport, regardless of query direction.
    ;WITH Raw AS (
        SELECT
            JSON_VALUE(j.value, '$.airline.name') AS AirlineName,
            UPPER(JSON_VALUE(j.value, '$.airline.iataCode')) AS AirlineIataCode,
            UPPER(JSON_VALUE(j.value, '$.flight.iataNumber')) AS FlightNumber,
            UPPER(JSON_VALUE(j.value, '$.aircraft.modelCode')) AS AircraftModelCode,
            -- Presence of a codeshared block means this row is a marketing
            -- code sold on a flight another carrier operates — Aviation
            -- Edge lists the same physical departure once per marketing
            -- code (we saw one DTW-CLT flight 5 times: AF, KL, VS, WS, and
            -- the operating DL row). Keeping every row would multiply-count
            -- one physical aircraft's passengers by however many airlines
            -- sell seats on it, so only rows WITHOUT this block survive.
            JSON_VALUE(j.value, '$.codeshared.flight.iataNumber') AS CodesharedFlag,
            UPPER(CASE WHEN @Direction = 'departure' THEN JSON_VALUE(j.value, '$.departure.gate')
                       ELSE JSON_VALUE(j.value, '$.arrival.gate') END) AS Gate,
            CASE WHEN @Direction = 'departure' THEN JSON_VALUE(j.value, '$.departure.scheduledTime')
                 ELSE JSON_VALUE(j.value, '$.arrival.scheduledTime') END AS TimeText,
            UPPER(CASE WHEN @Direction = 'departure' THEN JSON_VALUE(j.value, '$.arrival.iataCode')
                       ELSE JSON_VALUE(j.value, '$.departure.iataCode') END) AS OtherIata
        FROM OPENJSON(@RawJson) j
    )
    SELECT
        AirlineName,
        AirlineIataCode,
        FlightNumber,
        AircraftModelCode,
        COALESCE(Gate, '') AS Gate,
        OtherIata,
        -- scheduledTime is a bare "HH:MM", no date or timezone — combine
        -- with the date this batch was requested for. TRY_CONVERT so a
        -- malformed/missing time drops the row instead of failing the batch.
        TRY_CONVERT(DATETIME2(0), CONVERT(VARCHAR(10), @RequestedDate, 120) + ' ' + TimeText + ':00') AS ScheduledTime
    INTO #Operating
    FROM Raw
    WHERE CodesharedFlag IS NULL
      -- Aviation Edge's future-schedules endpoint doesn't distinguish
      -- passenger from freight service. Without this, a FedEx or UPS
      -- freighter matches the same aircraft-type seat lookup as a
      -- passenger flight and gets credited with real seats and a real
      -- load factor — a fictitious passenger count for a flight that
      -- carries none. See cfg.CargoAirline.
      AND NOT EXISTS (
          SELECT 1 FROM cfg.CargoAirline ca
          WHERE UPPER(ca.AirlineName) = UPPER(Raw.AirlineName)
             OR (ca.IataCode IS NOT NULL AND ca.IataCode = Raw.AirlineIataCode)
      );

    -- Duration isn't in this endpoint at all (no elapsed time, and the
    -- bare HH:MM times aren't enough to derive one without knowing both
    -- airports' timezones) — left NULL rather than guessed; the front end
    -- omits the duration line when it's missing.
    INSERT INTO stg.Flight (
        BatchId, AirportCode, Direction, AirlineName, AirlineIataCode, FlightNumber, AircraftModelCode,
        Gate, ScheduledTime, OtherAirportCode, OtherAirportCity, DurationMinutes
    )
    SELECT
        @BatchId, @AirportCode, @Direction, o.AirlineName, o.AirlineIataCode, o.FlightNumber, o.AircraftModelCode,
        o.Gate, o.ScheduledTime, o.OtherIata, COALESCE(ac.City, o.OtherIata), NULL
    FROM #Operating o
    LEFT JOIN cfg.AirportCity ac ON ac.IataCode = o.OtherIata
    WHERE o.ScheduledTime IS NOT NULL
      AND o.FlightNumber IS NOT NULL;

    -- Learn from whatever gate this batch DID see, so a future ingest of
    -- the same recurring flight number with a still-blank gate has
    -- something to fall back to (see mdl.FlightExposure's BestHistoricalGate).
    -- Scoped by AirportCode since a flight number is only meaningful within
    -- one airport's schedule.
    MERGE stg.GateHistory AS tgt
    USING (
        SELECT DISTINCT FlightNumber, @Direction AS Direction, @AirportCode AS AirportCode, Gate
        FROM #Operating
        WHERE Gate IS NOT NULL AND Gate <> ''
    ) AS src
        ON tgt.AirportCode = src.AirportCode AND tgt.FlightNumber = src.FlightNumber
        AND tgt.Direction = src.Direction AND tgt.Gate = src.Gate
    WHEN MATCHED THEN
        UPDATE SET ObservedCount = tgt.ObservedCount + 1, LastSeenAt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (AirportCode, FlightNumber, Direction, Gate, ObservedCount, LastSeenAt)
        VALUES (src.AirportCode, src.FlightNumber, src.Direction, src.Gate, 1, SYSUTCDATETIME());

    DROP TABLE #Operating;
END
GO
