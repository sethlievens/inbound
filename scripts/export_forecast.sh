#!/usr/bin/env bash
# Calls export.GetForecastJson once per active location and writes each to
# its own public/data/forecast-<code>.json, plus a small public/data/
# locations.json manifest the front end's location picker reads to list
# what else is available. Run this on the home workstation (or wherever
# SQL Server lives) after the nightly ingest + model run, or by hand
# during development.
#
# One file per location, not one combined artifact, so switching
# locations in the UI is just fetching a different small static file —
# same "never query the database at request time" rule this project has
# followed since the first commit.
#
# Required env vars:
#   SQLCMDPASSWORD   sa (or app login) password — never hardcode it here
# Optional env vars:
#   SQLCMDSERVER     default: localhost
#   SQLCMDUSER       default: sa
#   ASOF_DATE        default: today (per SQL Server's SYSDATETIME()).
#                    Pass an explicit date (YYYY-MM-DD) to pin a run against
#                    a specific seeded window, e.g. the hand-tuned demo data.
#
# Usage:
#   SQLCMDPASSWORD='...' ./scripts/export_forecast.sh
#   SQLCMDPASSWORD='...' ASOF_DATE=2026-07-18 ./scripts/export_forecast.sh

set -euo pipefail

: "${SQLCMDSERVER:=localhost}"
: "${SQLCMDUSER:=sa}"
: "${SQLCMDPASSWORD:?Set SQLCMDPASSWORD before running this script}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$REPO_ROOT/public/data"
SQLCMD="${SQLCMD_BIN:-sqlcmd}"

RAW_FILE="$(mktemp)"
JOINED_FILE="$(mktemp)"
trap 'rm -f "$RAW_FILE" "$JOINED_FILE"' EXIT

run_query() {
  local query="$1" out_file="$2" label="$3"
  "$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -d Inbound -y 0 -w 65535 -Q "$query" -o "$RAW_FILE"
  # sqlcmd wraps the single JSON column at a fixed console width even with
  # -y 0 -w set wide; the wrap always falls on a column boundary, never
  # mid-line with inserted whitespace, so joining lines back together
  # losslessly reconstructs the original JSON text.
  tr -d '\n\r' < "$RAW_FILE" > "$JOINED_FILE"
  python3 -c "
import json, sys
with open('$JOINED_FILE') as f:
    json.load(f)
" || { echo "$label produced invalid JSON — leaving $out_file untouched, bad output kept at $JOINED_FILE" >&2; trap - EXIT; exit 1; }
  cp "$JOINED_FILE" "$out_file"
}

# Locations manifest first, so the picker list always exists even if a
# later location's export fails partway through (fail toward stale, never
# toward blank, same rule the per-location files already follow).
run_query "SET NOCOUNT ON; EXEC export.GetLocationManifest;" "$DATA_DIR/locations.json" "locations manifest"
echo "Wrote $DATA_DIR/locations.json"

LOCATIONS_JSON="$(cat "$DATA_DIR/locations.json")"
python3 -c "
import json
for loc in json.loads('''$LOCATIONS_JSON'''):
    print(f\"{loc['locationId']}\t{loc['forecastFile']}\")
" | while IFS=$'\t' read -r LOCATION_ID FORECAST_FILE; do
  QUERY="SET NOCOUNT ON; EXEC export.GetForecastJson @LocationId=${LOCATION_ID}"
  if [ -n "${ASOF_DATE:-}" ]; then
    QUERY="$QUERY, @AsOfDate='${ASOF_DATE}'"
  fi
  QUERY="$QUERY;"

  OUT_FILE="$DATA_DIR/forecast-${FORECAST_FILE}.json"
  run_query "$QUERY" "$OUT_FILE" "location $LOCATION_ID"
  DAYS=$(python3 -c "import json; print(len(json.load(open('$OUT_FILE'))['days']))")
  echo "Wrote $OUT_FILE ($DAYS days)"
done
