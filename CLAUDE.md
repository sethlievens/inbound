# Inbound

Flight-driven demand forecasting for Plum Market at DTW Gate A36 (McNamara Terminal, Concourse A).

Full specification is `docs/BRIEF.md`. Read it before starting work — it defines every view, interaction, type scale, color, and config value. This file holds only the rules that always apply.

## What this is

A demo built to earn trust, not a production ordering system. It turns real future flight schedules into an hour-by-hour foot-traffic signal for one store. Nobody can verify its accuracy without Plum's POS data, and we deliberately do not use POS data.

Optimize in this order:

1. **Recognition** — the curve pulses like the real day at DTW
2. **Credibility of mechanism** — click any spike, see the real flights underneath
3. **Phone-first polish** — this doubles as a mobile reporting view

Do not optimize model precision past "plausible shape." Precision we cannot validate is invisible, and chasing it wastes the build.

## Hard rules

- **No request-time database connection.** The site reads a precomputed static JSON artifact. SQL Server exports `public/data/forecast.json` via `FOR JSON PATH`. No tunnels, no proxy functions, no live queries from Netlify.
- **No charting library.** Hand-roll bars in SVG or CSS. D3, Chart.js, and Recharts impose visual defaults that fight the art direction.
- **Model logic lives in T-SQL, not JavaScript.** The database is the engine, the site is the viewer. Never migrate model logic client-side.
- **Index, not raw counts, on headline bars.** 100 = average. Raw per-flight math appears only in the flight drill-down.
- **No scrolling to reveal time.** Both views fit their rows to the viewport. Navigation is discrete steps.
- **Two views only:** 14-day range and 18-hour day. No year view.
- Always keep a working `forecast.json` committed. Fail toward stale, never toward blank.

## Stack

- SQL Server 2022, local — ingest, model, export
- Static site on Netlify — Vite, vanilla JS or minimal React
- No browser storage APIs; in-memory state only

## Layout

- `sql/` — T-SQL schema, model, export procs
- `src/` — front end
- `public/data/forecast.json` — the committed artifact
- `docs/BRIEF.md` — full specification

## Workflow

- Plan before building. Show the plan and wait for approval.
- One build step at a time; the sequence is in `docs/BRIEF.md`.
- If you cannot connect to SQL Server to verify, write the scripts and state what to run manually. Do not guess at results.
- Ask when the brief is ambiguous rather than inventing a convention.
