<p align="center">
  <img src="public/inbound-mark.png" width="72" alt="Inbound" />
</p>

<h1 align="center">Inbound</h1>
<p align="center">A flight schedule, turned into an hour-by-hour foot traffic forecast for one airport store.</p>

<p align="center">
  <a href="https://inbound-dtw.netlify.app">inbound-dtw.netlify.app</a>
</p>

## What it is

Plum Market runs a small store at Gate A36 in the McNamara Terminal at Detroit Metro (DTW). Every flight through that concourse is a knowable, timestamped thing: which gate, how many seats, when it lands or leaves. Inbound turns that public flight schedule into a curve of expected foot traffic, broken down to the hour, with every spike traceable back to the actual flights causing it.

There's no point-of-sale data behind this and no historical sales to fit against. That's on purpose. The goal isn't forecast accuracy, it's proving the mechanism: that a store's busy and quiet hours are already visible in a flight schedule, before anyone hands over sales data to calibrate it. Click any bar and you see the real aircraft, seat counts, and gates driving that hour. Nothing on screen is a black box.

<p align="center">
  <img src="docs/screenshots/range-desktop.png" width="100%" alt="14-day range view, showing a bar per day with a demand tier and a peak-day stat card" />
</p>

## The three-layer split

```
Aviation Edge API  →  SQL Server 2022  →  forecast.json  →  Git  →  Netlify (static site)
                       staging → model → export
```

- **SQL Server is the engine.** It ingests flight schedules, runs the demand model, and exports one JSON artifact.
- **The site is just the viewer.** It fetches that JSON and renders it. No database connection at request time, no serverless proxy, no model logic in the browser.
- **Git is the handoff.** A nightly job refreshes the artifact and commits it. Netlify's build hook picks up the push and redeploys.

This isn't just a deployment convenience. A live tunnel from a public site back to a home SQL Server instance is a real outage risk for no visible upside, since a viewer can't tell "cached" from "live" by looking at a bar chart. Publishing a static artifact means the site is structurally incapable of showing a broken or empty screen, and it loads instantly, which reads as quality on its own.

## The model

All of it lives in T-SQL, in `sql/`, written to be read on its own. The shape:

**Per flight:**
```
exposure = seats(aircraftType) × loadFactor × geometryWeight(gate)
```

- `seats` comes from an aircraft-type lookup, not the flight record. Aviation Edge doesn't report seat counts.
- `loadFactor` is the one modeled assumption in the whole system. Everything else is a real scheduled flight. It's disclosed plainly in the footer rather than hidden in a constant.
- `geometryWeight` is the part a generic dashboard wouldn't build: the probability a passenger from that gate actually walks past A36, based on where the gate sits relative to the security checkpoint, the concourse tram stops, and A36 itself.

**Per flight, per hour:** a discrete flight becomes a distributed signal by spreading its exposure across the hours passengers are actually in motion, using a triangular dwell curve (departures build to a peak around 50 minutes before wheels-up, arrivals front-load right after landing). That spreading is done set-based, a tally table cross joined against every flight, normalized so each flight's weights sum to 1 across its own window. No cursors, no per-row loops.

**Aggregation:** hourly exposure rolls up to an index, `100 = an average hour`, so the headline number is always relative and never an unverifiable raw passenger count. Day-level index compares against a fixed reference day length rather than the day's own open hours, so a short Sunday correctly reads as lower volume instead of being normalized away.

Every model constant (load factor, gate zone weights, dwell curve timing, daypart windows) lives in a config table, not a literal in a view. Retuning the model is an `UPDATE` statement, not a redeploy.

## The interface

Two views, phone-first, no charting library. Bars are hand-rolled SVG and CSS because a charting library's defaults would fight the type system and spacing this design depends on.

- **14-day range view**, the landing view. Its width isn't an arbitrary "two weeks," it's two of Plum's actual reorder cycles, so a spike just past the visible edge never ambushes a buyer mid-order.
- **18-hour day view**, one tap into any day. Fits the store's actual open hours on one screen, no scrolling, ever, since bar height is computed from available space rather than a fixed pixel value.
- **Tap a hour, then tap a flight** to reach the raw math behind it: aircraft type, seats, load factor, gate, and the estimated share of passengers walking past A36. This drill-down is the credibility mechanism. The forecast is only convincing if anyone can check its work.

<table>
<tr>
<td width="50%"><img src="docs/screenshots/day-desktop.png" alt="18-hour day view with breakfast, lunch, and dinner section labels and a peak-time stat card" /></td>
<td width="50%"><img src="docs/screenshots/flight-desktop.png" alt="Flight drill-down showing route, aircraft, load factor, and the passengers-past-A36 math for one flight" /></td>
</tr>
<tr>
<td>Day view: daypart is a hairline and a label, never a bar color.</td>
<td>Depth 3: the raw math behind one flight, not just a bar.</td>
</tr>
</table>

<p align="center">
  <img src="docs/screenshots/range-mobile.png" width="320" alt="The same 14-day view on a phone-sized screen, unchanged layout" />
</p>
<p align="center"><em>Same layout at every breakpoint, since this doubles as the mobile reporting view.</em></p>

## Stack

- **SQL Server 2022** for ingest, modeling, and export. Four schemas: `stg` (untouched raw ingest), `cfg` (every tunable constant), `mdl` (the exposure model, views only), `export` (the one procedure that shapes the JSON).
- **Vite + TypeScript**, no framework, no charting library. A dark, condensed-type dashboard styled after wayfinding signage, self-hosted fonts, native View Transitions for the day-to-hour morph.
- **Aviation Edge** for live DTW flight schedules, refreshed nightly via cron and committed straight to the repo.
- **Netlify**, deployed from Git. No serverless functions, no environment secrets in the browser.

## Repo layout

```
sql/                  schema, config seed, model views, export and ingest-parse procedures
scripts/               nightly ingest + export + commit pipeline (bash + sqlcmd)
src/                   the front end (TypeScript, hand-rolled SVG/CSS charts)
public/data/forecast.json   the committed artifact the site reads, always kept fresh or stale, never blank
docs/BRIEF.md          the full project brief this was built against
docs/screenshots/      the images above
```

## Running it

```
npm install
npm run dev
```

The dev server reads the committed `public/data/forecast.json`, so the site works with no database connection at all. Regenerating that artifact from a live SQL Server instance is a separate step:

```
SQLCMDPASSWORD='...' ./scripts/export_forecast.sh
```

See the header comments in `scripts/` for the full env var list and the nightly refresh flow.
