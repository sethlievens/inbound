#!/usr/bin/env bash
# Calls export.GetForecastJson and writes the result to public/data/forecast.json.
# Run this on the home workstation (or wherever SQL Server lives) after the
# nightly ingest + model run, or by hand during development.
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
OUT_FILE="$REPO_ROOT/public/data/forecast.json"
SQLCMD="${SQLCMD_BIN:-sqlcmd}"

QUERY="SET NOCOUNT ON; EXEC export.GetForecastJson"
if [ -n "${ASOF_DATE:-}" ]; then
    QUERY="$QUERY @AsOfDate='${ASOF_DATE}'"
fi
QUERY="$QUERY;"

RAW_FILE="$(mktemp)"
JOINED_FILE="$(mktemp)"
trap 'rm -f "$RAW_FILE" "$JOINED_FILE"' EXIT

"$SQLCMD" -S "$SQLCMDSERVER" -C -U "$SQLCMDUSER" -d Inbound -y 0 -w 65535 -Q "$QUERY" -o "$RAW_FILE"

# sqlcmd wraps the single JSON column at a fixed console width even with
# -y 0 -w set wide; the wrap always falls on a column boundary, never
# mid-line with inserted whitespace, so joining lines back together
# losslessly reconstructs the original JSON text.
tr -d '\n\r' < "$RAW_FILE" > "$JOINED_FILE"

# Validate before touching the committed artifact. Fail toward stale,
# never toward blank: if this export is broken, the last known-good
# forecast.json stays exactly as it was.
python3 -c "
import json, sys
with open('$JOINED_FILE') as f:
    data = json.load(f)
print(f\"OK: {len(data['days'])} days, generatedAt={data['generatedAt']}\", file=sys.stderr)
" || { echo "Export produced invalid JSON — leaving $OUT_FILE untouched, bad output kept at $JOINED_FILE" >&2; trap - EXIT; exit 1; }

cp "$JOINED_FILE" "$OUT_FILE"
echo "Wrote $OUT_FILE"
