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
  # Re-running this script for a date already ingested (which every night
  # does, since the window slides forward by one day but mostly overlaps
  # yesterday's) must REPLACE that date's flights, not add to them — without
  # this, a date queried on two different nights would double-count its
  # exposure once both ingests' rows land in stg.Flight. Scoped by
  # AirportCode too, so re-ingesting DFW never touches DTW's rows.
  "$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -d Inbound -Q "
  DELETE FROM stg.Flight WHERE AirportCode = '$AIRPORT' AND CAST(ScheduledTime AS DATE) BETWEEN '$RANGE_START' AND '$RANGE_END';
  DELETE FROM stg.ApiIngestBatch WHERE AirportCode = '$AIRPORT' AND RequestedDate BETWEEN '$RANGE_START' AND '$RANGE_END';
  " -b

  for i in $(seq 0 $((WINDOW_DAYS - 1))); do
    QUERY_DATE="$(date_offset $((MIN_LOOKAHEAD_DAYS + i)))"
    for DIRECTION in departure arrival; do
      RESPONSE_FILE="$SCRATCH_DIR/${AIRPORT}_${DIRECTION}_${QUERY_DATE}.json"
      # A brief pause between calls — a full run now covers multiple
      # airports (more calls per run than when this was DTW-only), and a
      # burst of requests with no spacing tripped Aviation Edge's
      # per-minute rate limit partway through a run once already.
      sleep "${REQUEST_DELAY_SECONDS:-1}"
      curl -s "https://aviation-edge.com/v2/public/flightsFuture?key=${AVIATION_EDGE_KEY}&type=${DIRECTION}&iataCode=${AIRPORT}&date=${QUERY_DATE}" \
        -o "$RESPONSE_FILE"

      if ! python3 -c "
import json, sys
with open('$RESPONSE_FILE', encoding='utf-8') as f:
    data = json.load(f)
sys.exit(0 if isinstance(data, list) else 1)
" 2>/dev/null; then
        echo "  $AIRPORT $DIRECTION $QUERY_DATE: skipped (not a flight array — $(head -c 120 "$RESPONSE_FILE"))" >&2
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
print(f"INSERT INTO stg.ApiIngestBatch (RequestedDate, Direction, AirportCode, RawResponseJson) VALUES ('{query_date}', '{direction}', '{airport}', N'{escaped}');")
print("SET @BatchId = SCOPE_IDENTITY();")
print("EXEC stg.usp_ParseAviationEdgeBatch @BatchId;")
PYEOF

      "$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -i "$SQL_FILE" -b
      echo "  $AIRPORT $DIRECTION $QUERY_DATE: ingested" >&2
    done
  done
done

echo "Ingest complete." >&2
