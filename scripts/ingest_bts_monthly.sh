#!/usr/bin/env bash
# Pulls the last 12 months of airport-wide traffic (departures, passengers,
# seats, load factor) from BTS's T-100 Segment summary table, for one or
# more airports, and lands it in stg.BtsMonthlyVolume. No API key needed —
# data.bts.gov mirrors this BTS table on a public Socrata endpoint with a
# plain REST API, a lot more scriptable than transtats.bts.gov's own
# form-based download UI.
#
# Unlike the nightly Aviation Edge ingest, this doesn't need to run often:
# BTS publishes T-100 with a ~2-3 month reporting lag, so a fresh pull
# monthly (or even less often) is plenty. This exists to recalibrate
# cfg.LoadFactorSeasonalAdj and cfg.IndexBaseline against a real year of
# traffic instead of guessing — see sql/08_bts_recalibration.sql for the
# calibration math that consumes this table.
#
# Required env vars:
#   SQLCMDPASSWORD   SQL Server password
# Optional:
#   SQLCMDSERVER (default localhost), SQLCMDUSER (default sa)
#   AIRPORT_CODES (default: every distinct AirportCode in cfg.Location)
#   MONTHS (default 12)
#
# Usage:
#   SQLCMDPASSWORD='...' ./scripts/ingest_bts_monthly.sh
#   SQLCMDPASSWORD='...' AIRPORT_CODES=DFW ./scripts/ingest_bts_monthly.sh

set -euo pipefail

: "${SQLCMDPASSWORD:?Set SQLCMDPASSWORD before running this script}"
: "${SQLCMDSERVER:=localhost}"
: "${SQLCMDUSER:=sa}"
: "${MONTHS:=12}"

SQLCMD="${SQLCMD_BIN:-sqlcmd}"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

if [ -z "${AIRPORT_CODES:-}" ]; then
  AIRPORT_CODES="$("$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -d Inbound -h -1 -W -Q "SET NOCOUNT ON; SELECT DISTINCT AirportCode FROM cfg.Location WHERE IsActive = 1 ORDER BY AirportCode;" | tr -d '\r' | grep -v '^$' | tr '\n' ' ')"
fi

for AIRPORT in $AIRPORT_CODES; do
  # +1 month of headroom: BTS's most recent published month can repeat the
  # same calendar month as a year-old row still in the trailing window (e.g.
  # pulling "13 months back" to make sure 12 distinct calendar months are
  # covered even right after a new month posts). Deduped to one row per
  # calendar month (the most recent) in the Python step below.
  RAW_JSON="$SCRATCH_DIR/bts_${AIRPORT}.json"
  curl -s "https://data.bts.gov/resource/r495-tyji.json?origin_airport_code=${AIRPORT}&\$select=reporting_month,total_departures,total_passengers,total_seats,total_load_factor&\$order=reporting_month%20DESC&\$limit=$((MONTHS + 1))" \
    -o "$RAW_JSON"

  if ! python3 -c "
import json
with open('$RAW_JSON', encoding='utf-8') as f:
    data = json.load(f)
import sys
sys.exit(0 if isinstance(data, list) and len(data) > 0 else 1)
" 2>/dev/null; then
    echo "$AIRPORT: BTS request did not return a flight-month array — got: $(head -c 200 "$RAW_JSON")" >&2
    continue
  fi

  SQL_FILE="$SCRATCH_DIR/bts_${AIRPORT}_insert.sql"
  python3 - "$RAW_JSON" "$MONTHS" "$AIRPORT" > "$SQL_FILE" <<'PYEOF'
import json, sys

raw_path, months, airport = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(raw_path, encoding="utf-8") as f:
    rows = json.load(f)

# One row per calendar month, keeping the most recent if a month repeats.
by_month = {}
for r in rows:
    month = r["reporting_month"][:7]
    if month not in by_month:
        by_month[month] = r
rows = sorted(by_month.values(), key=lambda r: r["reporting_month"], reverse=True)[:months]

print("USE Inbound;")
print(f"DELETE FROM stg.BtsMonthlyVolume WHERE AirportCode = '{airport}';")
for r in rows:
    month_date = r["reporting_month"][:10]
    print(
        "INSERT INTO stg.BtsMonthlyVolume "
        "(AirportCode, ReportingMonth, TotalDepartures, TotalPassengers, TotalSeats, TotalLoadFactor) VALUES "
        f"('{airport}', '{month_date}', {int(float(r['total_departures']))}, "
        f"{int(float(r['total_passengers']))}, {int(float(r['total_seats']))}, {float(r['total_load_factor'])});"
    )
PYEOF

  "$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -i "$SQL_FILE" -b
  echo "$AIRPORT: BTS monthly volume ingested." >&2
done
