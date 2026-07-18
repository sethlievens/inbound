
# DTW Flight-Driven Demand Signal — Project Brief

## What this is (read this first, it changes every build decision)

This is a **demo / trust artifact**, not a production ordering system. It is being built to show Plum Market that flight schedules at DTW can be turned into an hour-by-hour foot-traffic signal for their store at Gate A36. The store sits in the McNamara Terminal, mid Concourse A, and serves an almost entirely Delta / SkyTeam passenger flow.

The goal is not forecast accuracy. Nobody can verify accuracy without Plum's point-of-sale (POS) data, and we are deliberately **not** using POS data in this build. The goal is to make Plum look at a curve that pulses like their real day and think "this person modeled our store without ever standing in it," then want to hand over their POS data so the model can be calibrated into real order quantities.

Optimize for three things, in order: **recognition** (the curve matches the rhythm they live), **credibility of mechanism** (you can click any spike and see the real flights underneath it), and **phone-first polish** (this doubles as a preview of the mobile CEO reporting view Plum said they want). Do not optimize model precision past "plausible shape." Precision we cannot validate is invisible and wastes build time.

Everything below serves those three priorities. When a choice is ambiguous, favor the one that protects the recognition moment.

---

## The pitch this artifact has to support

The demo has a choreography. Build so this sequence works:

1. Open on the curve. Let them recognize it before any explanation. Silence does the selling.
2. Click a spike. It decomposes into the actual flights driving that hour (aircraft type, seats, load factor, estimated passengers, share that walks past A36).
3. Deliver the POS line: *"The traffic curve is built entirely from flight schedules. The only thing I'm guessing at is what fraction of those people actually buy a breakfast sandwich versus walk past. That one number is the only thing your POS data would change, and it's the difference between a shape and a real order quantity."*
4. Deliver the platform line: *"This engine takes any demand signal. Flights today, weather or local events tomorrow. It turns a signal into a prep curve."*

The build must make steps 1 and 2 land hard. Steps 3 and 4 are spoken, but the architecture has to back them up (see Architecture and the pluggable-signal note).

---

## Architecture (three layers)

**Layer 1 — Data (SQL Server, home workstation).** Flight schedules in. Aviation Edge for the forward-looking schedule, BTS for calibration priors. Raw API responses land in staging tables untouched, then get transformed. See Data Pipeline Architecture.

**Layer 2 — Model (T-SQL).** Turns flights into an hour-by-hour traffic signal. This is where the cleverness lives, and it is mostly invisible to the viewer — but it is the most visible thing to anyone hiring a database developer, so write it to be read and ship it in the repo. See The Model.

**Layer 3 — Interface (static site on Netlify).** The thing they see. It consumes a precomputed JSON artifact and does no modeling of its own. Most of the build effort goes here even though layer 2 is smarter, because layer 2's quality is invisible in the room and layer 3's quality is the entire first impression. See Views, Interaction, and Visual Design.

The boundary between 2 and 3 is deliberate and is itself part of the pitch: **the engine runs in the database, the site is just the viewer.** No model logic migrates into JavaScript.

Architect the flight signal as **one pluggable input** to layer 2. The model should accept a generic "demand signal" (a set of timestamped, weighted contributions) and not care that today's signal happens to come from flights. This is architecturally trivial and rhetorically huge: it turns a one-off toy into a platform in their minds and flatters the CEO's-son idea while showing we are not limited to it.

---

## The Model (layer 2)

The core claim we are allowed to make: **the shape of the curve is derived from flight data; only the constants are assumptions.** Hourly resolution is the native resolution of a flight schedule (it is already a timestamped list), so we are propagating granularity, not inventing it. Say that in comments and in the pitch.

### Per-flight recipe

For each flight:

1. **Passengers** = `seats(aircraftType) * loadFactor`
   - `seats` comes from an aircraft-type lookup table (see Config).
   - `loadFactor` is a single visible, tunable assumption. Default domestic ~0.83. Allow a seasonal and daypart adjustment (see below). This is the ONE honest guess, and it must be surfaced in the UI as an adjustable input, not buried as a constant.

2. **Dwell curve** (turns a discrete flight into a continuous flow across hours):
   - **Departures:** passengers arrive at the gate area over roughly `[T - 90min, T - 10min]`, peaked around `T - 50min`. Model as a simple triangular or beta-shaped weight distributed across the affected hours.
   - **Arrivals:** passengers deplane over roughly `[T, T + 20min]`, front-loaded.

3. **Geometry weight** `w(gate)` = probability that a passenger for this flight walks past A36. This is the moat. Do not skip it and do not flatten it.

### Geometry (the part no generic dashboard would build)

Concourse A is ~1 mile, 62 gates, numbered A1–A78, with an elevated ExpressTram (South station A1–A28, Terminal station A29–A55, North station A56–A78). The central security checkpoint / link area feeds passengers into roughly the middle of the concourse, near the A38 Sky Club. **A36 sits right in that central funnel, in the Terminal tram zone.**

Consequences to encode as default pass-by weights (all tunable, these are starting priors, not truth):

- Passengers entering the concourse arrive at the center (near A36) and disperse. So A36 catches a large share of everyone entering.
- **South / near-center gates (roughly A1–A45):** high pass-by. Walkers from the central entry to these gates pass A36. Default weight ~0.6–0.85, highest for gates closest to A36.
- **Far-north gates (roughly A56–A78):** low pass-by. These passengers walk north from center (away from A36) or take the tram from Terminal station, skipping the store entirely. Default weight ~0.15–0.35.
- **Arrivals** funnel back through the center toward baggage / ground transport or connecting gates, so arrivals from south / center gates also strongly pass A36. DTW is a Delta hub, so a large share of traffic is **connecting** (gate to gate through the center), not origin-and-destination. Do not ignore connecting traffic. It is a big part of A36's best hours.

Aviation Edge gives a "most-used gate" per flight (a modal guess, not a guarantee), which is enough to bucket each flight into a zone and apply a weight. For the demo dataset, assign gates deliberately to produce a realistic zone mix.

### Aggregation and output

- `hourlyTraffic[h] = sum over all flights of (passengers * dwellFraction(flight, h) * geometryWeight(flight.gate))`
- Because DTW runs Delta connecting banks (waves), this sum should **pulse**, not smooth. The pulsing is the credibility. See Demo Data for the target bank structure.

### Output unit: index, not raw count

- Headline metric everywhere is a **traffic index**: `100 = average hour across the visible window` (or a trailing average). Never print an absolute passenger count on a bar. We cannot verify it, and its absence is itself the argument for giving us POS data.
- In the **flight-detail drill-down only**, show the raw per-flight math (this A321 at 83% is ~158 pax, ~0.7 of them pass A36). Headline stays honest and index-based; the underlying per-flight numbers are visible and defensible. This split is intentional. Do not "promote" raw counts to the headline.

### Daypart layer

Tag each hour as breakfast / lunch / dinner / off:
- Breakfast ~5–10am, lunch ~11am–2pm, dinner ~4–8pm, off = everything else (still shown, just desaturated).
- Daypart is the actionable output. Foot traffic is the input; prep and labor decisions happen at the daypart level. This is the same newsvendor framing as the "Grocery Demand Engine" (flights as the leading demand signal for daypart prep).
- Daypart also drives color (see Visual Design). Treat it as information, not decoration.

### Seasonality (bake it in, do not give it a screen)

Load factor and passenger assumptions should carry a light seasonal adjustment (August loads != February loads). This makes the 14-day view quietly season-aware without ever drawing a yearly view. There is deliberately **no year view** (it would overpromise, since far-out schedules degrade to "last year's seasonality re-drawn as a forecast," which is a weaker claim than the 14-day view's).

---

## Views (layer 3)

**Two views only.** Each is sized by what it means in the real world, not by a tidy calendar unit. Every number on screen is traceable to a reason.

### 1. Range view — 14 days (default landing view)

- 14 days ≈ two UNFI order cycles (order cycle + lead time defines the coverage period one order must survive; two cycles shows the order you are placing now plus the next one coming, so a spike just past the horizon does not ambush the buyer).
- 14 is a **default, not a law.** It is `2 * orderCycleDays`. Store `orderCycleDays` in config (default 7). If Plum's real cadence differs, the range re-derives. The view "means two order cycles"; 14 is just what that equals today.
- Emphasize the front cycle (the order being placed now) visually; the second cycle is preview / context.
- This is the order-decision altitude, which is why it is the default. When presenting, say "I set the default view to one order cycle plus lead time." That signals you understand their operation, not just their airport.

### 2. Day view — 18 hours (5am–11pm)

- 18 bars = the store's real open hours. This is genuinely fixed to the hours, but keep open hours **per day-of-week** in config (weekdays 5am–11pm, Sunday 6am–10pm per current public hours). Do not show closed overnight hours. The tool informs ordering and prep; nobody preps for 3am, so every bar on screen should be a bar someone could act on.
- The 5am and 11pm bars are real edges, not zero (5am = early pre-loaders for morning banks; 11pm still has traffic). Add faint "opens" / "closes" end labels so nobody misreads the first bar as an empty floor.
- The full open-day shape must fit on one screen (see Interaction). Seeing morning slam and evening bank together is the recognition moment; do not break it.

---

## Interaction model (layer 3)

### Fit-to-viewport, no scroll, ever

Both views fit their rows to the available height. Take viewport height, subtract fixed chrome (breadcrumb + view switcher + summary strip), divide by row count. **Bar size is an output, not a hardcoded pixel value.** Use flex / viewport units so it holds from a small phone to a desktop with no re-tuning. Do not use scroll to reveal more time; scroll is continuous and contextless and it destroys the at-a-glance recognition. Navigation happens in meaningful discrete steps instead (below).

### Two distinct navigation motions (keep them visually different)

- **Range navigation (jump the window):** moves the time window of a view (this 14-day span to the next). Lives with the view switcher at the top. Feels like a **jump / slide** to a new window.
- **Selection nudge (step within a view):** `‹ prev / next ›` steps the selected bar one unit (one day, or one hour). Lives **with the detail panel**, not the top. Used to fine-tune after a fat-fingered tap, and doubles as a scrubber to flip day-by-day and watch the detail panel update.

These two must not look alike or share placement. Range-nav = whole-window jump, up top. Selection-nudge = one-bar step, by the detail. Confusing them is the fastest way to make the whole thing feel muddled.

### Drill-down (the credibility engine)

Three depths of the same object. Never show all three at once. Deeper depth lives inside the shallower one.

- **Depth 1 — the curve.** The 14-day or 18-hour bars. Owns the most space, loads first.
- **Depth 2 — the selection.** Tap/hover a bar: reveal what it is made of. Traffic/day index value, the handful of flights driving it, count. Stays as bars/summary at this point.
- **Depth 3 — the flight.** Tap a flight in depth 2: the raw math. Aircraft type, seats, load factor, estimated passengers, gate zone, share passing A36, departure/arrival + time. This depth is the proof the machine is real. Reachable, never in the way.

**Revised 2026-07-18:** the 14-day view no longer has a depth-2 stop. Tapping a day bar goes straight into that day's 18-hour view (an altitude change, not a selection) — there is no intermediate day-summary popup to tap through first. Depth 2 still exists exactly as described above, just one level down: tap an hour in the day view to see what's driving it. A date-picker in the day view's breadcrumb (a native day selector) covers the case the old range-view depth-2 used to handle — jumping to a different day without returning to the 14-day view first.

**Representation change is the cue between "when" and "what's inside."** While navigating time (day bar to hour bars), everything stays bars and the metric stays the traffic index. The moment you open a specific unit into its flights (depth 3), the representation switches to **flight rows/cards** and the metric switches to **raw pax / seats / load**. That switch (bars to flight cards, index to raw numbers) tells the user they have crossed from "when" into "what's inside." Same tap, deliberately different feel.

### Transitions

- **Changing altitude** (pick a day in the 14-day view, go to that day's 18-hour view): the selected day bar should **expand / morph into** the hour bars (shared-element style), so the eye tracks one thing becoming the next level. This continuity is the difference between buttery and "the screen just changed." This is where the animation budget goes.
- **Changing range** (this window to next): horizontal slide, content streams in sideways.
- Keep motion small and purposeful. Over-animation is the tell of AI-generated design. One orchestrated moment (the altitude morph) beats scattered effects.
- Respect `prefers-reduced-motion`: fall back to instant transitions.

### Persistent orientation

- Always-visible breadcrumb + view switcher, e.g. `14-day  ›  Thu Jul 23  ›  7–8am`, with a clear way back out at every level. Zoom/drill UIs die from disorientation.
- **Selection persists across views.** Select a day in the 14-day view, drop into its 18-hour view, and it is that day's hours. Nothing resets. That continuity is subtle and it is what feels expensive.

---

## Responsive behavior (mobile is not desktop shrunk)

**Revised 2026-07-18, alongside the dark-dashboard pivot.** The axis flip below is no longer how this build works — superseded, not deleted, so the reasoning is on record.

Build **mobile-first.** If the drill-down works one-handed on a phone it works trivially on desktop, and the phone version is secretly the CEO reporting view Plum asked for.

**Row layout at every breakpoint, no axis flip.** The reference mockup's list — label left, bar in the middle, a demand-tier readout (Peak/High/Moderate/Low/Very low) on the right — is now used on desktop and mobile alike, for both the day-row (range view) and hour-row (day view) charts. Each row is still an equal flex share of the available height, so N rows always fit the viewport with no scroll regardless of N or screen width; only the row's internal font sizes shrink slightly below the mobile breakpoint. What's unchanged from the original axis-flip design: depth 2 still opens as a right-side rail on desktop and a bottom sheet on mobile, and depth 3 still pushes onto that same container. The range view's chart no longer opens a depth-2 rail on tap at all — see the Views section below.

~~**Axis flips at the mobile breakpoint:**~~

~~- **Desktop:** vertical bars. Wide screen, time flows left to right like a timeline. Hover surfaces depth 2 in a right-side rail without the curve moving (layout that jumps around feels amateur). Click a flight in the rail to reach depth 3.~~
~~- **Mobile:** horizontal bars, time running down the screen, magnitude across. Labels like "Thu Jul 23" read cleanly beside a horizontal bar instead of as a rotated stub, and full row width becomes the tap target (neutralizes thin bars). Depth 2 opens as a **bottom sheet** (the native mobile disclosure idiom, thumb-reachable); depth 3 pushes onto that sheet.~~

It must feel like **one product adapting**, not two designs. Same colors, same interaction grammar. A user who sees it on their phone then their desktop should feel the same tool turned sideways.

---

## Visual design direction

**Revised 2026-07-18.** Everything below the next paragraph described the original light-wayfinding direction. The user supplied a reference mockup (dark navy field, single blue accent, a "Peak time" stat card, a gauge, demand-tier labels) and asked to match its look and layout directly, having seen it rather than as a default — that's a materially different situation from an AI-generated dark-plus-accent theme, and the palette/component rules below are updated to match it. What survived the revision: condensed DIN typography, the five-role type scale, tabular numbers, one screen with progressive disclosure, fit-to-viewport with no scroll, copy voice, and the mono/signage contrast at depth 3. What changed: the palette (dark, not light), and the KPI-stat-card prohibition (the reference deliberately uses one "Peak time" card, so this build keeps exactly one).

- **One screen. Progressive disclosure.** No top nav, no legend if daypart color is self-evident from context, no settings panel beyond the one load-factor control, at most the single "Peak time" stat card the reference specifies. The absence of extra chrome beyond that is what makes the curve feel confident.
- **Copy:** plain, active voice, sentence case, named by what the user controls. Errors and empty states give direction in the interface's voice, never apologize, never go vague.
- Quality floor without announcing it: responsive to mobile, visible keyboard focus, reduced motion respected.

### Art direction: dark dashboard

The reference is a dark navy dashboard with a single saturated blue accent — a stat card up top, a gauge and demand-tier label in the detail panel, airline badges and route tags on flight rows. Typographic system stays wayfinding-derived (condensed DIN, tabular numbers, eyebrow labels), but the field, surfaces, and signature elements below follow the reference palette rather than the original glass-and-white terminal reference.

Why the change holds up: the CEO-on-a-phone use case and the "read at a glance, in motion" requirement are unaffected by color — dark-on-navy with high-contrast white text and one accent hue is just as legible under airport lighting as light-on-white was, and the single accent blue still keeps the field visually quiet the same way the daypart hues did (those hues are unused until build step 3's daypart breakout, and will need to coexist with this accent when that step lands — an open question to resolve then, not now).

### Typeface

**Condensed humanist sans, DIN lineage.** DIN 1451 was designed for German road and transit signage; the condensed cut is the visual language of gates, flight numbers, and terminal directories. Condensed also does real work here: it fits "Thu Jul 23" and 3-digit index values into narrow bar labels without truncating.

Self-host the font in the repo (woff2, subset to the characters used, primary weight preloaded). Do not hotlink Google Fonts — a third-party request is slower and risks a visible layout shift on the one device that matters. Options, best first:

1. **A licensed DIN condensed cut** (DIN Next Condensed, DIN 2014 Condensed). The authentic article, and the closest to real terminal signage. Worth it if the budget is trivial.
2. **Barlow Condensed** — free, DIN-adjacent, clean, excellent at small sizes. The pragmatic pick.
3. **Oswald** — free, more compressed and a touch more editorial. Good if the bar labels are tight.

Set a sensible fallback stack regardless, so a font failure degrades rather than breaks:
`font-family: "Barlow Condensed", "Avenir Next Condensed", "Roboto Condensed", "Arial Narrow", sans-serif;`

**Always enable tabular figures:** `font-variant-numeric: tabular-nums;` on every number. Non-negotiable, because the `‹ prev / next ›` scrubber updates values in place and proportional digits will make them jitter. Tabular figures are what make the scrubbing feel machined.

### Type scale (intentional hierarchy)

The principle: **few sizes, large gaps.** Evenly-spaced scales produce mush. Hierarchy comes from the *jump* between levels, so the hero number is dramatically larger than everything else and the supporting levels sit close together and stay quiet. Five roles, no more. If something needs a sixth size, it needs less content instead.

| Role | Mobile | Desktop | Weight | Tracking | Case |
|---|---|---|---|---|---|
| **Hero metric** (index value in detail panel) | 56px | 72px | 700 | -0.02em | — |
| **Title** (selected day/hour, e.g. "Thu Jul 23") | 20px | 24px | 600 | -0.01em | Title case |
| **Body** (bar labels, flight rows) | 15px | 15px | 400 | 0 | Sentence |
| **Eyebrow** (daypart tags, section labels, unit captions) | 11px | 11px | 600 | +0.12em | ALL CAPS |
| **Micro** (secondary meta: gate, aircraft code) | 10px | 10px | 400 | +0.04em | ALL CAPS |

Notes that make this work:
- The 56→20 jump is the drama. Do not add an intermediate size to "smooth" it.
- **The eyebrow is the signage move.** Small, bold, widely letterspaced all-caps is the single most recognizable gesture in wayfinding typography. Use it for `BREAKFAST`, `TRAFFIC INDEX`, `PASSENGERS PAST A36`. It costs nothing and does most of the aesthetic work.
- Large numbers get *negative* tracking; small caps labels get *positive* tracking. This inverse relationship is what separates considered typography from default.
- Two weights only (400 and 600/700). A third weight is almost always a hierarchy problem in disguise.
- Line height: 1.0–1.1 on the hero metric, 1.5 on body text. Tight display, comfortable reading.

### Color

Dark navy field with one saturated blue accent, per the approved reference mockup.

- **Field:** `#0A1424`, with a faint radial blue glow toward the top of the page
- **Surface** (detail panel / bottom sheet / stat card): `#101F36`, border `rgba(255,255,255,0.08)`
- **Ink:** `#F4F7FB`
- **Ink secondary:** `#8A9BB8`
- **Rules/hairlines:** `rgba(255,255,255,0.1)`, 1px, used sparingly
- **Accent:** `#3B82F6`, bright variant `#5B9CFF` — bar fills, hero numbers, selected states, the gauge fill, the peak marker

**No daypart hues — reversed 2026-07-18.** Build step 3 originally gave breakfast/lunch/dinner/off each their own bar color; the user asked to remove all of it: "I want all the bars the same color... daypart could be communicated by hairline dividers and eyebrow labels on the axis, never by color." Every bar is now the single accent hue regardless of daypart. Daypart shows up only in the day view, as a hairline + eyebrow label ("BREAKFAST", "LUNCH", "OFF HOURS", "DINNER") wherever the daypart changes from the previous hour — the range view never carried a meaningful per-row daypart anyway, since one day spans all of them. See `.claude/rules/design.md` for the implementation-level detail.

### Signature elements

- A single **peak marker** on the curve: one hairline rule with a small filled label chip reading `PEAK` in eyebrow type, rendered in the accent hue (not ink, since ink is now light text on a dark field). One marker, once per view, nowhere else.
- A **semicircle gauge** next to the hero index number in the detail panel, ticked at 0 / midpoint / the current view's own max — never an absolute scale, since the index has no fixed ceiling.
- A **demand-tier label** (Peak / Very high / High / Moderate / Low / Very low) under every hero number, bucketed relative to the current view's max.
- A single **"Peak time" stat card** in the page header, showing the busiest hour across the whole window — the one exception to "no KPI stat cards," because the reference mockup put it there deliberately. Do not add a second card.

### The mono/signage contrast (drill-down)

Interface chrome and bar labels use the condensed signage face. The **depth-3 flight detail** switches to a monospaced face for flight numbers, times, tail/aircraft codes, and the raw math (`seats × load = pax`). That typographic shift reinforces the interaction cue already specified: the user has crossed from *when* into *what's inside*, and the type changing from signage to machine-readable makes it feel like the machine was opened. Keep the mono restrained (one size, ink-secondary color) so it reads as data, not as a terminal-emulator gimmick.

### Spacing

4px base unit, all spacing a multiple of it. Generous margins around the curve — the confidence of this direction comes from empty space, not density. When in doubt, remove an element rather than tighten the gutters.

---

## Build sequence (do these in order; stop points are all demo-viable)

Build the pipeline before the polish, because the front end should never be fed data it will not receive in production.

0. **Pipeline skeleton:** SQL Server schema (staging, config tables, model views/procs), seeded with the hand-tuned demo dataset, exporting `forecast.json` via `FOR JSON PATH`. Commit the artifact. Deploy an empty Netlify site that fetches it. End to end on day one, ugly but real.
1. **MVP (must exist for the demo to land):** the 18-hour day view, rendered from the artifact, phone-readable, with the depth-3 flight drill-down working. Depth sells more than breadth in a first demo; a working single-day drill-down beats a shallow 14-day view.
2. **The 14-day range view** + range navigation, as the default landing view, with altitude morph into the day view.
3. **Daypart breakout** and coloring across both views.
4. **The load-factor assumption, surfaced.** Built initially as an adjustable slider (client-side re-scaling from values already in the artifact, no re-query) per this brief; revised 2026-07-18 at the user's request to a flat disclosure in the footer ("LOAD FACTOR 83% ASSUMED") instead — still visible, no longer interactive. The export still carries enough per-flight granularity to re-scale client-side if an adjustable control comes back later.
5. **Live Aviation Edge data, landed 2026-07-18.** Nightly automation is written (`scripts/ingest_aviation_edge.sh`, `scripts/nightly_refresh.sh`) but runs under **cron, not SQL Server Agent** — Agent isn't enabled on this instance, and its Linux build doesn't support the CmdExec step type a Windows install would use to shell out to a script like this anyway. See "Real constraints found integrating this" below for what changed along the way (minimum lookahead, codeshares, gate quality, terminal mismatches). The freshness stamp was already in place from step 0.

Chanel's-mirror rule throughout: build it, then remove one thing. Do not add a second data source for realism, settings nobody asked for, or model precision you cannot validate.

---

## Data pipeline architecture (SQL Server on-prem → static JSON → Netlify)

### The one rule: the live site must never query the home database

The site is hosted on Netlify. The SQL Server instance lives on a home workstation behind a residential connection. **Do not connect them at request time.** A Netlify Function tunneling to a home PC (via Cloudflare Tunnel, Tailscale, port forward, whatever) means the demo depends on that machine being awake, that ISP not hiccuping, and that tunnel staying up at the exact moment someone in a conference room taps a bar. The whole design philosophy of this project is that nothing on screen can stutter. A live database dependency is the single largest stutter risk in the stack, and it buys nothing the viewer can perceive.

**Instead: SQL Server is the engine, and it publishes a static artifact.** The model runs on-prem, exports precomputed JSON, and Netlify serves that JSON as a plain static file alongside the site. The site is then physically incapable of failing to load data. It also loads instantly, which reads as quality.

This is not a compromise, it is a better story. "The forecasting engine runs in SQL Server; the site is just the viewer" is exactly the division of labor a database developer should be demonstrating, and it mirrors what Plum said they want — a staged, source-of-truth database publishing approved data outward rather than apps reaching into the database directly.

### Layers

```
Aviation Edge API  ─┐
                    ├─→  SQL Server 2022 (home)  ─→  JSON artifact  ─→  Git repo  ─→  Netlify (static site)
BTS historical     ─┘     staging → model → export
```

**1. Ingest (SQL Server).** Pull Aviation Edge future schedules for DTW into staging tables. Land the raw API response first, unmodified, then transform. Keep raw and modeled separate so a bad transform never destroys source data. BTS historical loads the same way for load-factor and seasonality priors.

**2. Model (T-SQL).** This is the portfolio piece and it should be written to be read. Implement the exposure model from the model section as set-based T-SQL — views and stored procedures, not cursors:
- A flight-level view computing `EstimatedPassengers = seats × loadFactor` via a `seatsByAircraftType` lookup, joined to a `gateZoneWeights` table for the geometry weight.
- A dwell allocation that expands each flight across its affected hours (a numbers/tally table cross-joined to flights, applying the dwell curve fractions). This is the interesting SQL — turning discrete events into a distributed hourly signal set-based rather than procedurally.
- An aggregation rolling per-flight-per-hour exposure into `hourlyTraffic`, then into daypart and day-level rollups, plus the index normalization (100 = average hour in window).
- Keep all model constants in **config tables**, not hardcoded literals, mirroring the config list below. Tunable without a code change is both better engineering and a better demo answer.

**3. Export.** A stored procedure emits the finished 14-day structure using `FOR JSON PATH` (native in SQL Server 2022). One artifact, shaped exactly as the front end consumes it, so there is no transformation logic in the browser. Write it to a file (SQL Agent job, or a small script that calls the proc and writes output).

**4. Publish.** The export lands in the repo (`/public/data/forecast.json`) and is committed and pushed. Netlify's Git integration rebuilds and deploys automatically. Alternatively trigger a Netlify build hook. Nightly on a SQL Agent schedule is plenty — flight schedules do not change intraday in ways that matter here.

**5. Serve.** Netlify serves the static site and the JSON. No serverless functions required for v1. No secrets in the front end (the Aviation Edge key never leaves the home machine, which is also why the API call belongs on-prem rather than in a Netlify Function).

### Fallback discipline

**Always keep the last known-good `forecast.json` committed in the repo.** If the pipeline breaks, the API changes, or the home machine is off for a week, the site still deploys and still shows a coherent forecast. There should be no state in which the site can render empty. Fail toward stale, never toward blank.

### Freshness stamp (small feature, real credibility)

Include a `generatedAt` timestamp and a `source` field in the JSON, and render it quietly in the interface footer in micro type: `GENERATED 2026-07-18 04:00 · SQL SERVER 2022`. This does real work in the room — it proves the number on screen came out of a pipeline rather than a hardcoded array, without anyone having to ask. If the data is older than a threshold, say 48 hours, show the stamp in ink-secondary rather than hiding it. Visible staleness is more trustworthy than silent staleness.

### Demo data during development

Until the Aviation Edge subscription is live, seed the staging tables with a hand-tuned dataset rather than hardcoding JSON in the front end. Keeping the fake data *behind* the same SQL model means the pipeline is exercised end to end from day one and the switch to real data changes nothing downstream. Hand-tune it to DTW's real Delta rhythm so the curve triggers recognition:

- **Morning bank (roughly 6–9am):** heavy departure push. Biggest breakfast grab-and-go window. This should be a clear peak.
- **Midday lull (roughly 1–3pm):** visible trough. This is the "when NOT to prep" signal and it matters as much as the peaks.
- **Evening banks (roughly 4–8pm):** including transatlantic evening departures (Amsterdam, Paris CDG) and domestic coastal waves. Second major peak, dinner window.
- **Day-of-week variation:** e.g. Friday and Sunday travel-heavy, a midweek day lighter. Enough variation across the 14 days that the range view is not flat.
- **Aircraft mix and gates:** realistic Delta mainline + regional mix (A319/A320/A321, 717, 757, regional CRJ/E175), with a couple of widebodies (A330/767) on the evening transatlantic flights (large seat counts, big single-flight spikes, great for the drill-down). Assign gates across zones so geometry weights produce a believable curve (favor south/center gates near A36 for the visible spikes).

---

## Source data reference

**What comes from where:**

- **Flight schedule** (real, future): Aviation Edge.
- **Load factor and dwell timing** (historical patterns): BTS and industry priors.
- **Passenger count** (derived): `seats × loadFactor`, never empirical.

**Aviation Edge — Future Schedules API** (the schedule source, called from the home machine):

- Endpoint pattern: `https://aviation-edge.com/v2/public/flightsFuture?key=[KEY]&type=departure&iataCode=DTW&date=YYYY-MM-DD` (also `type=arrival`).
- Per-flight fields: `weekday`, `departure {iataCode, terminal, gate, scheduledTime}`, `arrival {...}`, `aircraft {modelCode, modelText}`, `airline {name, iataCode}`, `flight {number, iataNumber}`, and sometimes a `codeshared {airline, flight}` block.
- What it gives: **real future flights** — the schedule is algorithmically predicted from historical patterns, but the flights themselves are real scheduled events.
- What you use from it: aircraft type, gate, scheduled departure/arrival time, the other endpoint's IATA code.
- No elapsed flight time. Duration shown in the flight-detail route card only exists for the hand-tuned demo data (hand-authored per route); live-ingested flights leave `durationMinutes` null and the UI hides that line rather than guessing.

**Real constraints found integrating this (2026-07-18), none of which the brief above anticipated:**

1. **Minimum lookahead, not just a soft quality ceiling.** The API hard-rejects any date within about a week of the request (`{"error": "date must be above 2026-07-25"}` when queried on 2026-07-18) — `date must be above today+7`. This isn't the "beyond 14 days it degrades" caveat originally documented here; it's a floor, and it means the front several days of any "14-day forecast" starting at today can never be live data. The live window now starts at **today + 8 days**, not today — see `scripts/ingest_aviation_edge.sh`'s `MIN_LOOKAHEAD_DAYS`. The hand-tuned demo dataset is unaffected (it still starts at today) since it's a separate export run (`@AsOfDate` parameter), not a default the pipeline enforces.
2. **Codeshares multiply-list the same physical flight.** One DTW→CLT departure came back 5 times — once per marketing carrier (Air France, KLM, Virgin Atlantic, WestJet, and Delta itself as the operator) — identical gate, time, aircraft. Ingesting every row would count that one aircraft's passengers 5x. Fix: keep only rows without a `codeshared` block (the operating carrier's own row) — see `stg.usp_ParseAviationEdgeBatch`.
3. **Gate is often blank this far out** (~47% of DTW departures in an early sample), which the brief's "modal estimate" framing didn't quite capture — a live schedule can have no gate assigned yet at all, not just an approximate one. Left unhandled, the existing model already zeroes out unmatched gates, which would have silently thinned the curve exactly where the pitch's #1 priority (recognition) needs it to hold up. Fix: `stg.GateHistory` accumulates the gate each recurring flight number is actually observed at across nightly ingests, and a still-blank gate falls back to whichever gate that flight number has been seen at most; with no history yet either, it resolves to an `'unknown'` zone at a configured average weight (`cfg.GateZoneWeight`) rather than collapsing to zero.
4. **A gate string isn't always a Concourse A gate.** Non-SkyTeam carriers (American, United, Frontier, JetBlue, Lufthansa, Air Canada) show up at DTW too, at what appear to be North Terminal gates like "D31" or "B12" — a completely different building, not walking distance to A36. The original gate-number parse (`SUBSTRING(gate, 2, ...)`, assuming an "A" prefix) stripped the letter blindly and read "D31" as gate 31, bucketing it into Concourse A's own center zone. Fixed in `mdl.FlightExposure`: the parse only runs when the gate actually starts with "A"; anything else resolves to an explicit `'other-terminal'` zone with zero weight, not a fabricated Concourse A location.
5. **Aircraft variety is much wider than the hand-tuned set.** A single day's live pull surfaced ~30 aircraft type codes the demo dataset never used (A220s, 737 MAX variants, 787s, A350s, older CRJs and ERJs). `cfg.SeatsByAircraftType` now covers both, plus an `'UNKNOWN'` fallback row so an aircraft code neither list anticipates degrades to a plausible seat count instead of an `INNER JOIN` silently dropping the flight from the model.
6. **City names aren't in the response at all** — only IATA codes. `cfg.AirportCity` is a hand-seeded ~110-airport lookup for the route card's city names; anything not in it falls back to showing the bare code.
7. **A route-probability-by-destination idea was considered and set aside.** Hardcoding priors like "DTW→ATL is 95% likely near A36" was tempting but would have been exactly the "precision we can't validate" this brief warns against — those numbers aren't verified against DTW's actual gate-planning, only plausible-sounding. The gate-history mechanism (point 3) gets the same benefit empirically, from real observations, and only claims precision where the data actually supports it.
- Pricing: ~$149/mo; the demo integration above ran on a $7/30k-call trial tier — a full 14-day refresh (14 days × 2 directions) is ~28 calls, trivial against that budget.
- Key lives in a SQL Server credential / environment variable on the home machine (`AVIATION_EDGE_KEY`, read by `scripts/ingest_aviation_edge.sh` from a local secrets file, never committed). It must never reach the repo or the browser.

**BTS (Bureau of Transportation Statistics) — historical priors only:**

- Data: On-Time Performance (real scheduled/actual times, delays, cancellations, tail numbers); T-100 (aircraft type, but monthly aggregates only).
- What it gives: **no forward schedule** — it is historical data only.
- What you use from it: load-factor priors by month / day-of-week / route haul, seasonality adjustments, on-time/cancellation rates for a realism haircut.
- How: join tail numbers to the FAA registry to get aircraft type where T-100 does not. Use monthly averages as season and day-of-week buckets for the load factor assumption.
- Bulk load via SSIS or `BULK INSERT` into staging.

**Why neither source has passenger counts:**

Passenger counts are **derived**, not observed. The model computes them as `seats × loadFactor` because:
- Aviation Edge has no load or passenger data (it is a schedule, not an operations report).
- BTS has aggregate loads but not flight-level passenger counts, and not fine-grained enough (monthly, not daily or hourly).
- Load factor is the one honest assumption. Keep it tunable via the slider in the UI.

---

## Config values (config tables in SQL Server, mirrored into the exported JSON where the UI needs them)

No magic constants in either the T-SQL or the view code. Model constants live in database config tables so they are tunable with an UPDATE rather than a redeploy.

- `orderCycleDays` (default 7). Range view span = `2 * orderCycleDays`.
- `openHoursByDayOfWeek` (weekdays 5–23, Sunday 6–22; per-day-of-week array).
- `loadFactor` (default ~0.83), with optional seasonal and daypart multipliers.
- `seatsByAircraftType` lookup table.
- `gateZoneWeights` (pass-by weight per gate zone; south/center high, far-north low; tunable).
- `daypartWindows` (breakfast / lunch / dinner hour ranges).
- `dwellCurve` params (departure lead window ~90min peaked ~50min before; arrival ~20min after).
- Mobile breakpoint (axis-flip threshold).

---

## Explicitly out of scope for v1

- No year / 12-month view (overpromises; far-out schedules degrade to re-drawn seasonality).
- **No request-time database connection.** The site reads a precomputed static JSON artifact, always. No tunnels, no proxy functions, no live queries from Netlify.
- No POS data, and no absolute passenger counts on headline bars (index only; raw math lives in depth-3 drill-down).
- No second demand signal yet (architecture supports it, but flights only for v1).
- No settings/config UI beyond the single load-factor control.
- No model precision work beyond "plausible, pulsing shape."

---

## Honesty guardrail (state this in the room)

Until it is calibrated against POS, this proves a **hypothesis**, not a result: that flight traffic is a usable leading indicator for daypart demand at A36. It might turn out to predict weakly, because capture rate swings on things flights cannot see. That is fine, and saying it plainly is the frame that makes Plum curious enough to hand over the data: "I built the engine. Your data tells us if the hypothesis holds." Do not overclaim. Overclaiming is the one thing that flips wow into skepticism.

---

## Tech notes / preferences

**Front end (Netlify).** A build step is available, so use one, but stay light. Vite with vanilla JS/TS or a minimal React setup — whichever gets out of the way. The interface is two views, a detail panel, and a bar chart; it does not need a framework's help, and heavy dependencies would show up as load time on the very device the CEO will judge it on.

- **Hand-roll the bars in SVG or CSS. Do not add a charting library.** D3, Chart.js, and Recharts all impose their own visual defaults, and the entire art direction depends on controlling type, tracking, spacing, and the daypart color system precisely. Fighting a chart library's opinions costs more than drawing 18 rects. The chart is simple enough that hand-rolling is genuinely less work.
- **Fonts are now properly available.** Self-host the woff2 in the repo rather than hotlinking Google Fonts (faster, no third-party request, no layout shift). Barlow Condensed or Oswald are the DIN-adjacent options; if licensing a real DIN condensed cut is on the table it is the more authentic choice. Subset to the characters actually used. Preload the primary weight.
- Keep the JSON fetch trivial: one `fetch('/data/forecast.json')` on load. The artifact is already shaped for the view, so there is no client-side transformation.
- No browser storage APIs (in-memory state only).
- Deploy previews on by default — useful for sending a link before the meeting.

**Database (SQL Server 2022, home workstation).**

- Model logic lives in views and stored procedures, set-based, written to be read. **Ship the T-SQL in the repo** (a `/sql` directory with schema, model, and export scripts). Someone hiring a SQL Database Programmer may well open it, and it is the strongest artifact in the project. Comment it the way the pitch talks — the comments are part of the demo.
- Config in tables, not literals. Model constants tunable with an UPDATE, not a redeploy.
- Raw ingest tables stay untouched by the transform layer.
- Schedule ingest + model + export as a nightly SQL Agent job.

**What Claude Code should not do:** connect the deployed site to the home database at request time, add a serverless function that proxies to a tunnel, or move model logic into JavaScript. The SQL layer computing the model is the point, not an implementation detail.
plum-demo/INBOUND_EOF

