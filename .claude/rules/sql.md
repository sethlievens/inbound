---
paths:
  - "sql/**"
---

# T-SQL conventions

This code is a portfolio piece as much as an engine — it will be read by someone hiring a SQL developer. Write it to be read.

- Set-based only. No cursors, no row-by-row loops.
- Views and stored procedures, not ad-hoc scripts.
- Raw ingest tables are never modified by the transform layer.
- All model constants live in config tables, not literals. Tunable with an UPDATE, not a redeploy.
- Comment intent, not syntax. Explain the exposure model and dwell  allocation the way the brief explains them.

## The model

Per flight:
Exposure = (seats * loadFactor) * geometryWeight(gate)

Per flight per hour:


Exposure(flight, hour) = Exposure * dwellFraction(flight, hour)

`dwellFraction` sums to 1 across the flight's active hours. Departures spread over roughly T-90min to T-10min, peaked near T-50min. Arrivals over roughly T to T+20min, front-loaded.

Implement dwell allocation with a tally/numbers table cross-joined to flights. This is the most interesting SQL in the project — turning discrete events into a distributed hourly signal, set-based.

`geometryWeight` folds walk-by probability and gate proximity into a single 0-1 value from a config table. Do not multiply them separately; that double-counts distance.

Aggregate to hourly, then daypart, then day. Normalize to an index where 100 = average hour in the window.

## Export

One stored procedure emits the 14-day structure via `FOR JSON PATH`, shaped exactly as the front end consumes it. No transformation logic in the browser.

Export flight-level granularity, not just rollups — the load-factor slider re-scales client-side and needs per-flight-per-hour rows carrying seats, loadFactor, passengers, geometryWeight, and passengersPastA36.

Include `generatedAt` and `source` fields for the freshness stamp.
