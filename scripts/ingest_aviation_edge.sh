#!/usr/bin/env bash
# Pulls DTW future schedules from Aviation Edge for the live window and
# lands them through stg.usp_ParseAviationEdgeBatch. Run this on the home
# workstation (SQL Server lives there); the key never leaves this machine.
#
# Aviation Edge enforces a *minimum* lookahead — dates within ~7 days of
# today are rejected outright ("date must be above ..."), which the brief
# didn't document. MIN_LOOKAHEAD_DAYS below is that discovered floor, not
# a tunable preference; the live forecast window starts there rather than
# at "today" because the near days simply aren't queryable.
#
# Required env vars:
#   AVIATION_EDGE_KEY   your API key — never written to any file in the repo
#   SQLCMDPASSWORD      SQL Server password
# Optional:
#   SQLCMDSERVER (default localhost), SQLCMDUSER (default sa)
#   WINDOW_DAYS (default 14)
#
# Usage:
#   AVIATION_EDGE_KEY='...' SQLCMDPASSWORD='...' ./scripts/ingest_aviation_edge.sh

set -euo pipefail

: "${AVIATION_EDGE_KEY:?Set AVIATION_EDGE_KEY before running this script}"
: "${SQLCMDPASSWORD:?Set SQLCMDPASSWORD before running this script}"
: "${SQLCMDSERVER:=localhost}"
: "${SQLCMDUSER:=sa}"
: "${WINDOW_DAYS:=14}"

MIN_LOOKAHEAD_DAYS=8
SQLCMD="${SQLCMD_BIN:-sqlcmd}"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

date_offset() {
  date -u -d "+$1 days" +%Y-%m-%d 2>/dev/null || date -u -v"+$1"d +%Y-%m-%d
}

RANGE_START="$(date_offset "$MIN_LOOKAHEAD_DAYS")"
RANGE_END="$(date_offset $((MIN_LOOKAHEAD_DAYS + WINDOW_DAYS - 1)))"
echo "Ingesting $WINDOW_DAYS days starting $RANGE_START (today+$MIN_LOOKAHEAD_DAYS)..." >&2

# Re-running this script for a date already ingested (which every night
# does, since the window slides forward by one day but mostly overlaps
# yesterday's) must REPLACE that date's flights, not add to them — without
# this, a date queried on two different nights would double-count its
# exposure once both ingests' rows land in stg.Flight. Deleting by
# TrafficDate right before the loop keeps each night's run idempotent for
# whichever dates it touches, without disturbing the hand-tuned demo data
# outside this window.
"$SQLCMD" -S "${SQLCMDSERVER:-localhost}" -C -U "${SQLCMDUSER:-sa}" -d Inbound -Q "
DELETE FROM stg.Flight WHERE CAST(DtwScheduledTime AS DATE) BETWEEN '$RANGE_START' AND '$RANGE_END';
DELETE FROM stg.ApiIngestBatch WHERE RequestedDate BETWEEN '$RANGE_START' AND '$RANGE_END';
" -b

for i in $(seq 0 $((WINDOW_DAYS - 1))); do
  QUERY_DATE="$(date_offset $((MIN_LOOKAHEAD_DAYS + i)))"
  for DIRECTION in departure arrival; do
    RESPONSE_FILE="$SCRATCH_DIR/${DIRECTION}_${QUERY_DATE}.json"
    curl -s "https://aviation-edge.com/v2/public/flightsFuture?key=${AVIATION_EDGE_KEY}&type=${DIRECTION}&iataCode=DTW&date=${QUERY_DATE}" \
      -o "$RESPONSE_FILE"

    if ! python3 -c "
import json, sys
with open('$RESPONSE_FILE', encoding='utf-8') as f:
    data = json.load(f)
sys.exit(0 if isinstance(data, list) else 1)
" 2>/dev/null; then
      echo "  $DIRECTION $QUERY_DATE: skipped (not a flight array — $(head -c 120 "$RESPONSE_FILE"))" >&2
      continue
    fi

    SQL_FILE="$SCRATCH_DIR/${DIRECTION}_${QUERY_DATE}.sql"
    python3 - "$RESPONSE_FILE" "$DIRECTION" "$QUERY_DATE" > "$SQL_FILE" <<'PYEOF'
import sys
raw_path, direction, query_date = sys.argv[1], sys.argv[2], sys.argv[3]
with open(raw_path, encoding="utf-8") as f:
    raw = f.read()
escaped = raw.replace("'", "''")
print("USE Inbound;")
print("DECLARE @BatchId INT;")
print(f"INSERT INTO stg.ApiIngestBatch (RequestedDate, Direction, RawResponseJson) VALUES ('{query_date}', '{direction}', N'{escaped}');")
print("SET @BatchId = SCOPE_IDENTITY();")
print("EXEC stg.usp_ParseAviationEdgeBatch @BatchId;")
PYEOF

    "$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -i "$SQL_FILE" -b
    echo "  $DIRECTION $QUERY_DATE: ingested" >&2
  done
done

echo "Ingest complete." >&2
