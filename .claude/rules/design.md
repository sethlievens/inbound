---
paths:
  - "src/**"
---

# Art direction: dark dashboard (revised 2026-07-18)

Superseded the original light-wayfinding direction: the user supplied a reference mockup (dark navy field, single blue accent, card-based stat block) and asked to match it directly — "I like the look and feel and layout of this... the rest can be mapped and made to look like the picture." Treat this file's tokens as current; the original rationale for a light field (avoiding "near-black-plus-acid-accent as AI-design house style") no longer applies because the user explicitly chose that look after seeing it, which is a different situation than defaulting to it unprompted.

Kept from the original direction: condensed DIN typography, the five-role type scale, tabular numbers, fit-to-viewport bars with no scroll, the two-distinct-navigation-motions rule, and the depth-3 mono-type switch. Only the palette and the "no KPI stat card" restraint rule were reversed — the header now carries a "Peak time" stat card, per the reference.

## Type

Condensed humanist sans, DIN lineage. Barlow Condensed or Oswald, self-hosted woff2, subset to characters used, primary weight preloaded. Never hotlink Google Fonts.

`font-variant-numeric: tabular-nums` on every number. Non-negotiable — the prev/next scrubber updates values in place and proportional digits will visibly jitter.

| Role | Mobile | Desktop | Weight | Tracking | Case |
|---|---|---|---|---|---|
| Hero metric | 56px | 72px | 700 | -0.02em | — |
| Title | 20px | 24px | 600 | -0.01em | Title |
| Body | 15px | 15px | 400 | 0 | Sentence |
| Eyebrow | 11px | 11px | 600 | +0.12em | ALL CAPS |
| Micro | 10px | 10px | 400 | +0.04em | ALL CAPS |

Five roles, no more. The 56-to-20 jump is the drama; do not add an intermediate size to smooth it. Large numbers take negative tracking, small caps take positive tracking. Two weights only.

## Color

- Field `#0A1424` (subtle radial blue glow toward the top), surface `#101F36`, surface border `rgba(255,255,255,0.08)`
- Ink `#F4F7FB`, ink-secondary `#8A9BB8`, hairlines `rgba(255,255,255,0.1)`
- Accent `#3B82F6`, accent-bright `#5B9CFF` — the one saturated hue in the system, used for bar fills, hero numbers, selected states, and the gauge fill

**No hue encoding, anywhere — revised 2026-07-18, reversing build step 3.** Daypart hues on the bar fill were tried and then explicitly removed at the user's request: "I want all the bars the same color... daypart could be communicated by hairline dividers and eyebrow labels on the axis, never by color." Every bar (day view and range view both) is now the single accent gradient regardless of daypart. Daypart is communicated in the day view only (a whole day in the range view spans every daypart, so it never had a meaningful per-row daypart to show) via `.row-section` — a hairline plus an eyebrow label ("BREAKFAST", "LUNCH", "OFF HOURS", "DINNER") inserted wherever the daypart changes from the previous hour row. The hour-detail panel's daypart tag (`.daypart-chip`) is a plain eyebrow-style label too, not a colored chip. `--breakfast`/`--lunch`/`--dinner`/`--off-fill` tokens were removed from `:root` entirely rather than left unused.

## Signature elements

- One peak marker per view: a hairline rule with a small filled label chip reading PEAK in eyebrow type, in the accent hue now rather than ink. Once per view, nowhere else.
- A semicircle gauge pairs with the hero index number in the detail panel (day index and traffic index both), scaled to the current view's own max — not an absolute ceiling, since the index has no fixed one.
- A demand tier label (Peak / Very high / High / Moderate / Low / Very low) sits under every hero number, bucketed relative to the current view's max — see `demandTier` in `src/lib/format.ts`.

## Interaction

- Both views fit rows to viewport height. Bar size is computed from available space, never a hardcoded pixel value.
- Two distinct motions that must not look alike: range navigation jumps the window and lives at the top; selection nudge steps one bar and lives with the detail panel.
- Altitude change morphs the selected bar into the next level. Range change slides horizontally.
- Depth 3 (flight detail) switches from bars to flight cards and from index to raw numbers, in mono type. That switch signals crossing from "when" into "what is inside."
- Row layout (label left, bar middle, demand tier right) at every breakpoint, not an axis flip — see docs/BRIEF.md's Responsive section for why. Detail panel is still a right-side rail on desktop and a bottom sheet on mobile.
- 4px spacing base unit. Respect `prefers-reduced-motion`.

Restraint still matters even with the stat card: one card, one hue, no top nav, no interactive settings control at all — the load-factor slider was tried and then removed at the user's request in favor of a flat "LOAD FACTOR 83% ASSUMED" disclosure in the footer. The stat card earns its place because the reference put it there deliberately — don't add a second one.
