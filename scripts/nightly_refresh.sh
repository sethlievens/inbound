#!/usr/bin/env bash
# Nightly pipeline: ingest live Aviation Edge schedules, re-export
# forecast.json, commit and push so Netlify's Git integration picks it up.
#
# Runs under cron rather than a SQL Server Agent job — SQL Agent isn't
# enabled on this instance, and on Linux it doesn't support the CmdExec
# step type Windows SQL Agent would use to shell out to a script like this
# one anyway. Cron is the native scheduler for a pipeline that is, at its
# core, "call an HTTP API, then call sqlcmd a few times."
#
# Secrets (AVIATION_EDGE_KEY, SQLCMDPASSWORD) are read from a local file
# OUTSIDE the repo, never committed — see the header of that file below.
#
# One-time setup:
#   mkdir -p ~/.config/inbound
#   cat > ~/.config/inbound/secrets.env <<'EOF'
#   AVIATION_EDGE_KEY=your-key-here
#   SQLCMDPASSWORD=your-sql-password-here
#   EOF
#   chmod 600 ~/.config/inbound/secrets.env
#
# Then add to crontab (crontab -e), e.g. nightly at 4am:
#   0 4 * * * /home/sethl/projects/inbound/scripts/nightly_refresh.sh >> ~/.config/inbound/nightly_refresh.log 2>&1

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="${INBOUND_SECRETS_FILE:-$HOME/.config/inbound/secrets.env}"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "$(date -u '+%F %T') ERROR: secrets file not found at $SECRETS_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

export AVIATION_EDGE_KEY SQLCMDPASSWORD
: "${SQLCMD_BIN:=sqlcmd}"

echo "$(date -u '+%F %T') Starting nightly refresh..."

MIN_LOOKAHEAD_DAYS=8
ASOF_DATE="$(date -u -d "+${MIN_LOOKAHEAD_DAYS} days" +%Y-%m-%d 2>/dev/null || date -u -v"+${MIN_LOOKAHEAD_DAYS}"d +%Y-%m-%d)"

cd "$REPO_ROOT"
SQLCMD_BIN="$SQLCMD_BIN" ./scripts/ingest_aviation_edge.sh
SQLCMD_BIN="$SQLCMD_BIN" ASOF_DATE="$ASOF_DATE" ./scripts/export_forecast.sh

if ! git diff --quiet -- public/data/forecast.json; then
  git add public/data/forecast.json
  git commit -m "Nightly forecast refresh: $ASOF_DATE"
  git push
  echo "$(date -u '+%F %T') Committed and pushed updated forecast.json."
else
  echo "$(date -u '+%F %T') forecast.json unchanged, nothing to commit."
fi

echo "$(date -u '+%F %T') Nightly refresh complete."
