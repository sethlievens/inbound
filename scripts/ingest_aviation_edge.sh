#!/usr/bin/env bash
# Pulls future schedules from Aviation Edge for one or more airports and
# lands them through stg.usp_ParseAviationEdgeBatch. Run this on the home
# workstation (SQL Server lives there); the key never leaves this machine.
#
# Aviation Edge enforces a *minimum* lookahead — dates within ~7 days of
# today are rejected outright ("date must be above ..."), which the brief
# didn't document. MIN_LOOKAHEAD_DAYS below is that discovered floor, not
# a tunable preference; the live forecast window starts there rather than
# at "today" because the near days simply aren't queryable. Tested
# separately: the far end goes out to +351 days before the API rejects a
# date, far more room than this pipeline uses today.
#
# Required env vars:
#   AVIATION_EDGE_KEY   your API key — never written to any file in the repo
#   SQLCMDPASSWORD      SQL Server password
# Optional:
#   SQLCMDSERVER (default localhost), SQLCMDUSER (default sa)
#   AIRPORT_CODES (default: every distinct AirportCode in cfg.Location)
#   WINDOW_DAYS (default: OrderCycleDays * 2 * WindowCount from cfg.OrderCycle,
#     so bumping the window-count config is enough on its own — this script
#     doesn't need its own copy of that number kept in sync by hand)
#
# Usage:
#   AVIATION_EDGE_KEY='...' SQLCMDPASSWORD='...' ./scripts/ingest_aviation_edge.sh

set -euo pipefail

: "${AVIATION_EDGE_KEY:?Set AVIATION_EDGE_KEY before running this script}"
: "${SQLCMDPASSWORD:?Set SQLCMDPASSWORD before running this script}"
: "${SQLCMDSERVER:=localhost}"
: "${SQLCMDUSER:=sa}"

MIN_LOOKAHEAD_DAYS=8
SQLCMD="${SQLCMD_BIN:-sqlcmd}"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

sql_scalar() {
  "$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -d Inbound -h -1 -W -Q "SET NOCOUNT ON; $1"
}

if [ -z "${AIRPORT_CODES:-}" ]; then
  AIRPORT_CODES="$(sql_scalar "SELECT DISTINCT AirportCode FROM cfg.Location WHERE IsActive = 1 ORDER BY AirportCode;" | tr -d '\r' | grep -v '^$' | tr '\n' ' ')"
fi
if [ -z "${WINDOW_DAYS:-}" ]; then
  WINDOW_DAYS="$(sql_scalar "SELECT OrderCycleDays * 2 * WindowCount FROM cfg.OrderCycle;" | tr -d '\r ')"
fi

TODAY="$(date -u +%Y-%m-%d)"

# Offsets are always relative to TODAY, captured once above — not to
# "whatever the wall clock says right now," which drifted forward mid-run
# once already (multiple airports with a per-request rate-limit delay adds
# up to several minutes, long enough to cross a UTC midnight) and produced
# a real one-day mismatch between the first and last airport in a run.
date_offset() {
  date -u -d "$TODAY +$1 days" +%Y-%m-%d 2>/dev/null || date -u -j -v"+$1"d -f "%Y-%m-%d" "$TODAY" +%Y-%m-%d
}

RANGE_START="$(date_offset "$MIN_LOOKAHEAD_DAYS")"
RANGE_END="$(date_offset $((MIN_LOOKAHEAD_DAYS + WINDOW_DAYS - 1)))"
echo "Ingesting $WINDOW_DAYS days starting $RANGE_START (today+$MIN_LOOKAHEAD_DAYS) for: $AIRPORT_CODES" >&2

for AIRPORT in $AIRPORT_CODES; do
  for i in $(seq 0 $((WINDOW_DAYS - 1))); do
    QUERY_DATE="$(date_offset $((MIN_LOOKAHEAD_DAYS + i)))"
    for DIRECTION in departure arrival; do
      RESPONSE_FILE="$SCRATCH_DIR/${AIRPORT}_${DIRECTION}_${QUERY_DATE}.json"

      # Aviation Edge's per-minute rate limit can trip partway through a
      # multi-airport run. A rate-limit response is transient, not a real
      # "this date has no data" answer, so it gets retried with backoff
      # before this date is given up on — giving up too early is what
      # previously caused good data to be replaced with nothing (see the
      # REPLACE comment below: the delete only runs after a fetch actually
      # succeeds, specifically so a failed retry loop leaves that date's
      # existing rows alone instead of blanking them).
      ATTEMPT=1
      MAX_ATTEMPTS=5
      while :; do
        sleep "${REQUEST_DELAY_SECONDS:-1}"
        curl -s "https://aviation-edge.com/v2/public/flightsFuture?key=${AVIATION_EDGE_KEY}&type=${DIRECTION}&iataCode=${AIRPORT}&date=${QUERY_DATE}" \
          -o "$RESPONSE_FILE"

        if python3 -c "
import json, sys
with open('$RESPONSE_FILE', encoding='utf-8') as f:
    data = json.load(f)
sys.exit(0 if isinstance(data, list) else 1)
" 2>/dev/null; then
          break
        fi

        if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
          echo "  $AIRPORT $DIRECTION $QUERY_DATE: skipped after $ATTEMPT attempts (not a flight array — $(head -c 120 "$RESPONSE_FILE")) — leaving existing rows in place" >&2
          RESPONSE_FILE=""
          break
        fi
        echo "  $AIRPORT $DIRECTION $QUERY_DATE: attempt $ATTEMPT failed ($(head -c 80 "$RESPONSE_FILE")), retrying..." >&2
        sleep "$((ATTEMPT * 5))"
        ATTEMPT=$((ATTEMPT + 1))
      done

      if [ -z "$RESPONSE_FILE" ]; then
        continue
      fi

      SQL_FILE="$SCRATCH_DIR/${AIRPORT}_${DIRECTION}_${QUERY_DATE}.sql"
      python3 - "$RESPONSE_FILE" "$DIRECTION" "$QUERY_DATE" "$AIRPORT" > "$SQL_FILE" <<'PYEOF'
import sys
raw_path, direction, query_date, airport = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(raw_path, encoding="utf-8") as f:
    raw = f.read()
escaped = raw.replace("'", "''")
print("USE Inbound;")
print("DECLARE @BatchId INT;")
# Re-running this script for a date already ingested (which every night does,
# since the window slides forward by one day but mostly overlaps yesterday's)
# must REPLACE that date's flights, not add to them — without this, a date
# queried on two different nights would double-count its exposure once both
# ingests' rows land in stg.Flight. This delete only runs here, immediately
# before inserting a response that's already confirmed to be a real flight
# array, so a date whose fetch fails/retries-out keeps its last-known-good
# rows (stale) instead of being wiped (blank).
print(f"DELETE FROM stg.Flight WHERE AirportCode = '{airport}' AND Direction = '{direction}' AND CAST(ScheduledTime AS DATE) = '{query_date}';")
print(f"DELETE FROM stg.ApiIngestBatch WHERE AirportCode = '{airport}' AND Direction = '{direction}' AND RequestedDate = '{query_date}';")
print(f"INSERT INTO stg.ApiIngestBatch (RequestedDate, Direction, AirportCode, RawResponseJson) VALUES ('{query_date}', '{direction}', '{airport}', N'{escaped}');")
print("SET @BatchId = SCOPE_IDENTITY();")
print("EXEC stg.usp_ParseAviationEdgeBatch @BatchId;")
PYEOF

      "$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -i "$SQL_FILE" -b
      echo "  $AIRPORT $DIRECTION $QUERY_DATE: ingested" >&2
    done
  done

  # Aviation Edge structurally refuses to return a schedule inside
  # MIN_LOOKAHEAD_DAYS ("date must be above ..."), so today..today+7 can
  # never be fetched directly — that's not a bug, but it did leave those
  # days with zero flights (and a dayIndex of 0, "very low") every single
  # night, forever, for every airport. Since Aviation Edge's own future
  # schedule is itself a repeating weekly template (confirmed empirically:
  # identical flight numbers recur exactly 7 and 14 days apart), the real
  # schedule for one of these blind dates already exists in what was just
  # ingested above, two weeks out on the same day-of-week. Copying it back
  # isn't a guess dressed up as fact — it's the same underlying schedule,
  # fetched from a date Aviation Edge was actually willing to answer for.
  for i in $(seq 0 $((MIN_LOOKAHEAD_DAYS - 1))); do
    BLIND_DATE="$(date_offset "$i")"
    TEMPLATE_DATE="$(date_offset $((i + 14)))"
    "$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -d Inbound -Q "
    DELETE FROM stg.Flight WHERE AirportCode = '$AIRPORT' AND CAST(ScheduledTime AS DATE) = '$BLIND_DATE';
    -- BatchId is NULL, not copied from the template row: a copied row
    -- doesn't belong to that batch's own RequestedDate, and once the
    -- window rolls forward far enough for the template date to be
    -- re-fetched for real, that re-fetch's own per-date DELETE would
    -- otherwise hit this FK from an unrelated date and abort the whole
    -- ingest (this happened once — see the git history on this line).
    INSERT INTO stg.Flight (BatchId, Direction, AirlineName, AirlineIataCode, FlightNumber, AircraftModelCode, Gate, ScheduledTime, OtherAirportCode, OtherAirportCity, DurationMinutes, AirportCode)
    SELECT NULL, Direction, AirlineName, AirlineIataCode, FlightNumber, AircraftModelCode, Gate,
           DATEADD(day, -14, ScheduledTime), OtherAirportCode, OtherAirportCity, DurationMinutes, AirportCode
    FROM stg.Flight
    WHERE AirportCode = '$AIRPORT' AND CAST(ScheduledTime AS DATE) = '$TEMPLATE_DATE';
    " -b
    echo "  $AIRPORT blind-window backfill $BLIND_DATE (from $TEMPLATE_DATE): done" >&2
  done
done

# Aviation Edge's predicted schedule is genuinely sparse for Southwest at
# CMH on Mondays/Tuesdays (confirmed repeatedly against the raw,
# unmodified API response, including a same-day recheck — not an ingest
# bug, and not fixed by retrying). cfg.SouthwestCmhTemplate holds one
# real healthy weekday's worth of Southwest's CMH schedule; every
# Monday/Tuesday/Wednesday across the whole exported window gets
# replaced with it, every night, rather than a one-time manual patch
# that a future real ingest would silently overwrite back to sparse.
if echo "$AIRPORT_CODES" | grep -qw CMH; then
  "$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -d Inbound -Q "
  DECLARE @Start DATE = '$TODAY';
  DECLARE @End DATE = '$RANGE_END';

  ;WITH Spine AS (
      SELECT DATEADD(DAY, t.n, @Start) AS D FROM cfg.Tally t WHERE t.n <= DATEDIFF(DAY, @Start, @End)
  ),
  TargetDates AS (
      SELECT D FROM Spine WHERE DATENAME(WEEKDAY, D) IN ('Monday','Tuesday','Wednesday')
  )
  DELETE f
  FROM stg.Flight f
  JOIN TargetDates td ON CAST(f.ScheduledTime AS DATE) = td.D
  WHERE f.AirportCode = 'CMH' AND f.AirlineName LIKE 'southwest%';

  ;WITH Spine AS (
      SELECT DATEADD(DAY, t.n, @Start) AS D FROM cfg.Tally t WHERE t.n <= DATEDIFF(DAY, @Start, @End)
  ),
  TargetDates AS (
      SELECT D FROM Spine WHERE DATENAME(WEEKDAY, D) IN ('Monday','Tuesday','Wednesday')
  )
  INSERT INTO stg.Flight (BatchId, Direction, AirlineName, AirlineIataCode, FlightNumber, AircraftModelCode, Gate, ScheduledTime, OtherAirportCode, OtherAirportCity, DurationMinutes, AirportCode)
  SELECT NULL, tpl.Direction, 'southwest airlines', 'WN', tpl.FlightNumber, tpl.AircraftModelCode, tpl.Gate,
         CAST(CONVERT(VARCHAR(10), td.D, 120) + ' ' + CONVERT(VARCHAR(8), tpl.TimeOfDay, 108) AS DATETIME2),
         tpl.OtherAirportCode, tpl.OtherAirportCity, tpl.DurationMinutes, 'CMH'
  FROM cfg.SouthwestCmhTemplate tpl
  CROSS JOIN TargetDates td;
  " -b
  echo "CMH Southwest weekly template applied ($TODAY to $RANGE_END, Mon/Tue/Wed)." >&2
fi

echo "Ingest complete." >&2
