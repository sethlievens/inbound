import type { Day, Daypart, Flight, Forecast, LocationManifestEntry } from "./lib/types";
import type { DemandTier } from "./lib/format";
import {
  dayIndexTier,
  demandTier,
  formatAirlineName,
  formatDateRange,
  formatDayTitle,
  formatDuration,
  formatFlightTime,
  formatGeneratedAt,
  formatHourRange,
  geometryWeightTier,
  loadFactorTier,
} from "./lib/format";
import { renderGauge } from "./lib/gauge";

type View = "range" | "day";

interface State {
  forecast: Forecast;
  view: View;
  dayIdx: number | null; // selection persists across views, per the brief
  selectedHour: number | null;
  selectedFlightId: number | null;
  // Which windowDays-sized slice of forecast.days the range view is
  // currently showing. jumpToDay/jumpToDayKeepView keep this in sync with
  // whichever window the selected day actually lives in, so returning to
  // the range view never silently strands the selection in a window
  // that's no longer on screen.
  windowIdx: number;
}

const STALE_THRESHOLD_MS = 48 * 60 * 60 * 1000;

// Brief descriptions for jargon terms, surfaced via the click-to-open info
// buttons next to each label. Kept in one place so wording stays consistent
// wherever a term reappears (range view vs. day view vs. flight detail).
const TERM_INFO: Record<string, string> = {
  trafficIndex:
    "100 is an average hour in the current window. Above 100 is busier than typical, below 100 is quieter.",
  dayIndex:
    "100 is an average day's total volume. Compared against a fixed 18-hour reference day, so a day open fewer hours (like Sunday) correctly reads lower — that's less total volume, not weaker demand per hour.",
  loadFactor:
    "Share of seats filled, 0 to 1. The one modeled assumption in this forecast — everything else comes from the flight schedule. The footer shows the baseline; this flight's own value is that baseline adjusted for season and time of day, not an adjustable control.",
  geometryWeight:
    "Estimated share of this gate's passengers who walk past this location, based on where the gate sits in the concourse.",
  passengersPastA36:
    "Estimated passengers from this flight walking past this location in this hour: seats × load factor × geometry weight, spread across the hours the flight is in motion.",
};

function infoTip(term: keyof typeof TERM_INFO, label: string, align: "left" | "right" = "left"): string {
  return `
    <details class="info-tip${align === "right" ? " info-tip--right" : ""}">
      <summary aria-label="What does ${label} mean?">i</summary>
      <p>${TERM_INFO[term]}</p>
    </details>
  `;
}

// Self-hosted widget marks (public/airlines/), not hotlinked — the four
// busiest carriers across the six locations. Any other carrier code falls
// back to a plain text badge rather than a missing-image icon.
const AIRLINE_LOGOS: Record<string, string> = {
  DL: "/airlines/delta.svg",
  AA: "/airlines/american.svg",
  UA: "/airlines/united.svg",
  WN: "/airlines/southwest.svg",
};

/** Badge/logo keyed off the flight's own airlineIataCode, straight from
 * stg.Flight, not guessed from the flight number. A regex on the flight
 * number (stripping non-letter characters from the front) used to do this
 * and quietly broke for any carrier whose IATA code starts with a digit —
 * UPS ("5X") and Aeromexico Connect ("5D") both do, and both fly into DTW,
 * so real flights were showing a bare "?" badge instead of a carrier code
 * the database already had on hand. */
function airlineBadge(f: Flight): string {
  const code = f.airlineIataCode || "?";
  const logo = AIRLINE_LOGOS[code];
  return logo
    ? `<span class="flight-row__badge flight-row__badge--logo"><img src="${logo}" alt="${code}" /></span>`
    : `<span class="flight-row__badge">${code}</span>`;
}

// Small line icons for the flight-detail stat rows — hand-drawn geometric
// shapes (not pulled from any icon library), colored via currentColor so
// they pick up the accent blue from .stat-mini__icon.
const STAT_ICONS: Record<string, string> = {
  aircraft: `<path d="M3 11l18-8-8 18-2-8-8-2z"/>`,
  gate: `<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="3" width="12" height="18" rx="1"/><line x1="15" y1="12" x2="15" y2="12.01"/></g>`,
  seats: `<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 4v9a3 3 0 0 0 3 3h6a3 3 0 0 0 3-3V4"/><path d="M8 20v-4h8v4"/></g>`,
  people: `<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="7" r="3"/><path d="M2 21v-2a5 5 0 0 1 5-5h4a5 5 0 0 1 5 5v2"/><circle cx="17" cy="7" r="3"/><path d="M15 11.5A5 5 0 0 1 19 16v2h2"/></g>`,
  scale: `<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v18"/><path d="M5 7h14"/><path d="M5 7l-3 7a3 3 0 0 0 6 0z"/><path d="M19 7l-3 7a3 3 0 0 0 6 0z"/></g>`,
  trend: `<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 17 9 11 13 15 21 6"/><polyline points="14 6 21 6 21 13"/></g>`,
  clock: `<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 15 14"/></g>`,
};

function statIcon(name: keyof typeof STAT_ICONS): string {
  return `<svg class="stat-mini__icon" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">${STAT_ICONS[name]}</svg>`;
}

// Daypart is communicated by section dividers and eyebrow labels on the
// hour list, never by color — every bar is the same accent hue regardless
// of daypart (see .row__fill). Revised 2026-07-18; see design.md.
const DAYPART_LABELS: Record<Daypart, string> = {
  breakfast: "Breakfast",
  lunch: "Lunch",
  dinner: "Dinner",
  off: "Off hours",
};

function prefersReducedMotion(): boolean {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

/** Wraps a render in the native View Transition API when available, so an
 * altitude change (range day -> day hours) or a selection change gets a
 * smooth morph instead of an instant redraw. Falls back to a plain call
 * when unsupported or when the user asked for reduced motion. */
function withTransition(fn: () => void): void {
  const docWithTransitions = document as Document & {
    startViewTransition?: (cb: () => void) => void;
  };
  if (prefersReducedMotion() || !docWithTransitions.startViewTransition) {
    fn();
    return;
  }
  docWithTransitions.startViewTransition(fn);
}

/** Average and max per-flight contribution to this location's traffic, deduped by
 * flightId (a flight appears once per hour it dwells in, so summing its
 * own passengersPastA36 across those rows recovers its one true total —
 * the same fact mdl.FlightExposure.Exposure holds server-side, just
 * reconstructed from the already-exported per-hour rows rather than
 * re-deriving the model). Computed once from the whole window: a plain
 * aggregate over exported data, not a new model computation. */
function computeFlightExposureStats(forecast: Forecast): { avg: number; max: number } {
  const totals = new Map<number, number>();
  for (const day of forecast.days) {
    for (const hour of day.hours) {
      for (const f of hour.flights) {
        totals.set(f.flightId, (totals.get(f.flightId) ?? 0) + f.passengersPastA36);
      }
    }
  }
  const values = [...totals.values()];
  const avg = values.reduce((a, b) => a + b, 0) / (values.length || 1);
  const max = Math.max(...values, 1);
  return { avg, max };
}

export function mount(
  root: HTMLElement,
  forecast: Forecast,
  locations: LocationManifestEntry[],
  onSwitchLocation: (forecastFile: string) => void
): void {
  const state: State = {
    forecast,
    view: "range",
    dayIdx: null,
    selectedHour: null,
    selectedFlightId: null,
    windowIdx: 0,
  };

  document.title = `${forecast.location.displayName} — Inbound`;

  const flightExposureStats = computeFlightExposureStats(forecast);

  root.innerHTML = `
    <header class="page-header">
      <div class="brand">
        <div class="brand__eyebrow"><img class="brand__mark" src="/inbound-mark.png" alt="" />Inbound · Flight-driven demand signal</div>
        <span class="brand__hero-wrap">
          <select class="brand__hero" id="location-picker" aria-label="Switch location">
            ${locations
              .map(
                (loc) =>
                  `<option value="${loc.forecastFile}" ${loc.locationId === forecast.location.locationId ? "selected" : ""}>${loc.airportCode} ${loc.gateLabel}</option>`
              )
              .join("")}
          </select>
        </span>
        <div class="brand__subtitle">Expected foot traffic in front of this location</div>
      </div>
      <button class="stat-card" id="stat-card" aria-label="Jump to the peak">
        <div>
          <div class="stat-card__label" id="stat-label"></div>
          <div class="stat-card__value" id="stat-value"></div>
          <div class="stat-card__tier" id="stat-tier"></div>
        </div>
        <div class="stat-card__bars" aria-hidden="true">
          <span style="height:35%"></span><span style="height:55%"></span><span style="height:75%"></span><span style="height:100%"></span>
        </div>
      </button>
    </header>
    <div class="breadcrumb" id="breadcrumb"></div>
    <div class="main" id="main">
      <div class="chart-col">
        <div class="chart-header" id="chart-header"></div>
        <div class="chart" id="chart" role="list"></div>
      </div>
      <aside class="detail" id="detail" aria-live="polite"></aside>
    </div>
    <footer class="footer" id="footer"></footer>
  `;

  const mainEl = root.querySelector<HTMLElement>("#main")!;
  const breadcrumbEl = root.querySelector<HTMLElement>("#breadcrumb")!;
  const chartHeaderEl = root.querySelector<HTMLElement>("#chart-header")!;
  const chartEl = root.querySelector<HTMLElement>("#chart")!;
  const detailEl = root.querySelector<HTMLElement>("#detail")!;
  const footerEl = root.querySelector<HTMLElement>("#footer")!;
  const statLabelEl = root.querySelector<HTMLElement>("#stat-label")!;
  const statValueEl = root.querySelector<HTMLElement>("#stat-value")!;
  const statTierEl = root.querySelector<HTMLElement>("#stat-tier")!;

  // A location switch tears down and reloads the whole app with a
  // different location's own forecast file — not a re-render, since
  // there's no meaningful selection to carry across two different
  // airports' data the way a day selection carries across windows.
  root.querySelector<HTMLSelectElement>("#location-picker")!.addEventListener("change", (e) => {
    onSwitchLocation((e.target as HTMLSelectElement).value);
  });

  root.querySelector<HTMLButtonElement>("#stat-card")!.addEventListener("click", handleStatCardClick);

  // Updated by renderRows on every render so setupDragSelect always commits
  // through whichever handler (range vs. day view) is currently active.
  let activeRowHandler: { dataAttr: string; onClick: (key: number) => void } | null = null;

  function currentDay(): Day | undefined {
    return state.dayIdx === null ? undefined : state.forecast.days[state.dayIdx];
  }

  /** The windowDays-sized slice of forecast.days the range view currently
   * shows — the range view's peak-day stat card and chart both scope to
   * just this slice, not every day the export happens to carry, so
   * switching windows always shows that window's own peak, not a global
   * one that might not even be visible on screen. */
  function currentWindowDays(): Day[] {
    const wd = state.forecast.windowDays;
    return state.forecast.days.slice(state.windowIdx * wd, state.windowIdx * wd + wd);
  }

  function totalWindows(): number {
    return Math.ceil(state.forecast.days.length / state.forecast.windowDays);
  }

  function currentFlight(): Flight | undefined {
    if (state.selectedHour === null || state.selectedFlightId === null) return undefined;
    const hour = currentDay()?.hours.find((h) => h.hour === state.selectedHour);
    return hour?.flights.find((f) => f.flightId === state.selectedFlightId);
  }

  // ---------- navigation actions ----------

  /** Range view: tapping a day jumps straight into its hour-by-hour view —
   * no intermediate preview step. */
  function jumpToDay(idx: number): void {
    withTransition(() => {
      state.dayIdx = idx;
      state.windowIdx = Math.floor(idx / state.forecast.windowDays);
      state.view = "day";
      state.selectedHour = null;
      state.selectedFlightId = null;
      render();
    });
  }

  /** Day view: the breadcrumb date picker jumps to a different day while
   * staying in the hour-by-hour view. Keeps windowIdx in sync too, so
   * returning to the range view shows whichever window this day actually
   * lives in instead of silently snapping back to the first one. */
  function jumpToDayKeepView(idx: number): void {
    state.dayIdx = idx;
    state.windowIdx = Math.floor(idx / state.forecast.windowDays);
    state.selectedHour = null;
    state.selectedFlightId = null;
    render();
  }

  /** Range view: the window picker jumps to a different windowDays-sized
   * slice of forecast.days without touching any existing day selection. */
  function jumpToWindow(idx: number): void {
    withTransition(() => {
      state.windowIdx = idx;
      render();
    });
  }

  function goToRangeView(): void {
    withTransition(() => {
      state.view = "range";
      state.selectedHour = null;
      state.selectedFlightId = null;
      render();
    });
  }

  function selectHour(hour: number | null): void {
    state.selectedHour = hour;
    state.selectedFlightId = null;
    render();
  }

  function selectFlight(flightId: number | null): void {
    state.selectedFlightId = flightId;
    render();
  }

  function stepHour(delta: 1 | -1): void {
    const day = currentDay();
    if (!day || state.selectedHour === null) return;
    const next = state.selectedHour + delta;
    if (next < day.openHour || next >= day.closeHour) return;
    selectHour(next);
  }

  // ---------- header stat card: peak day (range view) / peak hour (day view) ----------

  /** Shared with renderRangeChart, which needs the same "which row in this
   * window is the peak" answer for its own marker — kept in one place so
   * the stat card and the chart can never disagree about which day it is. */
  function peakDayIdxInWindow(days: Day[]): number {
    return days.reduce((best, d, i) => (d.dayIndex > days[best].dayIndex ? i : best), 0);
  }

  function renderStatCard(): void {
    let peakIndex: number;
    if (state.view === "range") {
      const days = currentWindowDays();
      const peakIdx = peakDayIdxInWindow(days);
      statLabelEl.textContent = "Peak day";
      statValueEl.textContent = formatDayTitle(days[peakIdx].date);
      peakIndex = days[peakIdx].dayIndex;
    } else {
      const day = currentDay()!;
      statLabelEl.textContent = "Peak time";
      statValueEl.textContent = formatHourRange(day.peakHour);
      peakIndex = day.hours.find((h) => h.hour === day.peakHour)?.index ?? 0;
    }
    // This card shows the actual peak day/hour, so its tier is always
    // "Peak" (isPeak=true) — the same label the peak bar itself gets
    // everywhere else in the app. A stray hardcoded `false` here used to
    // make this always read "Very high demand" instead, regardless of
    // what the peak day/hour actually was.
    statTierEl.textContent = `${Math.round(peakIndex)} · ${demandTier(1, true).label}`;
  }

  /** The stat card doubles as a shortcut to whatever it's showing — tapping
   * "Peak day" jumps straight into that day, tapping "Peak time" (already
   * inside a day) selects that hour, the same destination a tap on the
   * peak bar itself would reach. Reads state fresh rather than closing
   * over anything captured at the last render, since this listener is
   * attached once at mount, not re-attached on every render. */
  function handleStatCardClick(): void {
    if (state.view === "range") {
      const days = currentWindowDays();
      const idx = peakDayIdxInWindow(days);
      const windowOffset = state.windowIdx * state.forecast.windowDays;
      jumpToDay(windowOffset + idx);
    } else {
      const day = currentDay();
      if (day) selectHour(day.peakHour);
    }
  }

  // ---------- breadcrumb: hierarchy with a way back out at every level ----------

  function renderBreadcrumb(): void {
    const day = currentDay();
    const segments: string[] = [];
    const windowDays = state.forecast.windowDays;
    const windows = totalWindows();

    if (state.view === "range") {
      // The window picker replaces what used to be a pair of disabled
      // arrows either side of a static date range — arrows small enough to
      // be fiddly targets, and disabled ones at that, since this export
      // only ever carried one window. A picker on the date range itself
      // (same idiom as the day picker below) scales to however many
      // windows the export actually has, no separate widget needed.
      segments.push(`
        <span class="breadcrumb__range breadcrumb__seg--stacked">
          <span class="breadcrumb__seg-secondary">${windowDays}-day forecast</span>
          <span class="breadcrumb__picker-wrap">
            <select class="breadcrumb__picker" id="crumb-window-picker" aria-label="Jump to a different ${windowDays}-day window">
              ${Array.from({ length: windows }, (_, i) => {
                const start = state.forecast.days[i * windowDays];
                const end = state.forecast.days[Math.min((i + 1) * windowDays, state.forecast.days.length) - 1];
                return `<option value="${i}" ${i === state.windowIdx ? "selected" : ""}>${formatDateRange(start.date, end.date)}</option>`;
              }).join("")}
            </select>
          </span>
        </span>
      `);
    } else {
      // Shows the window the selected day actually lives in (kept in sync
      // by jumpToDay/jumpToDayKeepView), so this always matches what's on
      // screen after clicking back, not the export's full span.
      const days = currentWindowDays();
      const dateRange = formatDateRange(days[0].date, days[days.length - 1].date);
      segments.push(`
        <span class="breadcrumb__range">
          <button class="breadcrumb__seg breadcrumb__seg--stacked is-link" id="crumb-range">
            <span class="breadcrumb__seg-secondary">${windowDays}-day forecast</span>
            <span class="breadcrumb__seg-primary">${dateRange}</span>
          </button>
        </span>
      `);
    }

    if (state.view === "day" && day) {
      segments.push(`
        <span class="breadcrumb__picker-wrap">
          <select class="breadcrumb__picker" id="crumb-day-picker" aria-label="Jump to a different day">
            ${state.forecast.days
              .map((d, i) => `<option value="${i}" ${i === state.dayIdx ? "selected" : ""}>${formatDayTitle(d.date)}</option>`)
              .join("")}
          </select>
        </span>
      `);
      if (state.selectedHour !== null) {
        segments.push(`<span class="breadcrumb__sep">›</span>`);
        segments.push(`<span class="breadcrumb__seg">${formatHourRange(state.selectedHour)}</span>`);
      }
    }

    breadcrumbEl.innerHTML = segments.join("");

    breadcrumbEl.querySelector("#crumb-range")?.addEventListener("click", () => {
      if (state.view === "day") goToRangeView();
    });
    breadcrumbEl.querySelector<HTMLSelectElement>("#crumb-window-picker")?.addEventListener("change", (e) => {
      jumpToWindow(Number((e.target as HTMLSelectElement).value));
    });
    breadcrumbEl.querySelector<HTMLSelectElement>("#crumb-day-picker")?.addEventListener("change", (e) => {
      jumpToDayKeepView(Number((e.target as HTMLSelectElement).value));
    });
  }

  function renderChartHeader(): void {
    const unitLabel = state.view === "range" ? "Day" : "Time";
    chartHeaderEl.innerHTML = `
      <span class="chart-header__label">${unitLabel}</span>
      <span class="chart-header__mid">Expected traffic</span>
      <span class="chart-header__tier">Demand</span>
    `;
  }

  // ---------- shared row-chart renderer: label left, bar middle, tier right ----------

  interface RowItem {
    key: number;
    label: string;
    value: number;
    isPeak: boolean;
    isSelected: boolean;
    isPreview: boolean;
    // Set only by the day view (daypart name per hour) — the range view
    // leaves this undefined, since a whole day spans every daypart and
    // dividing it that way wouldn't mean anything. When present, a change
    // from the previous row's sectionLabel draws a hairline + eyebrow
    // label above the row — this, not color, is how daypart is
    // communicated (see .row__fill: every bar is the same hue).
    sectionLabel?: string;
    // Set only by the range view: dayIndexTier's fixed-baseline tier,
    // precomputed by the caller since only it knows whether "relative to
    // this window" (demandTier, the default below) or "relative to a real
    // annual average" (dayIndexTier) is the right comparison for what
    // it's rendering.
    tier?: DemandTier;
  }

  function renderRows(items: RowItem[], maxValue: number, dataAttr: string, onClick: (key: number) => void): void {
    chartEl.innerHTML = items
      .map((item, i) => {
        const mag = Math.max(4, (item.value / maxValue) * 100);
        const tier = item.tier ?? demandTier(item.value / maxValue, item.isPeak);
        // The tier column reads better bare ("High", "Peak") than repeating
        // "demand" on every row; the fuller "Very high demand" phrasing is
        // kept where it appears standalone (stat card, hero block).
        const tierLabel = tier.label.replace(/ demand$/i, "");
        const cycleDivider = item.isPreview && !items[i - 1]?.isPreview
          ? `<div class="cycle-divider" aria-hidden="true"></div>`
          : "";
        const isNewSection = item.sectionLabel !== undefined && item.sectionLabel !== items[i - 1]?.sectionLabel;
        const sectionHeader = isNewSection
          ? `<div class="row-section">${i > 0 ? `<div class="row-section__line"></div>` : ""}<span class="row-section__label">${item.sectionLabel}</span></div>`
          : "";
        return `
          ${cycleDivider}
          ${sectionHeader}
          <button
            class="row${item.isSelected ? " is-selected" : ""}${item.isPreview ? " is-preview" : ""}"
            role="listitem"
            aria-pressed="${item.isSelected}"
            aria-label="${item.label}, index ${Math.round(item.value)}"
            data-${dataAttr}="${item.key}"
          >
            <span class="row__label">${item.label}</span>
            <span class="row__track"><span class="row__fill" style="width:${mag}%"></span></span>
            <span class="row__tier" style="color:var(--${tier.className})">${tierLabel}</span>
          </button>
        `;
      })
      .join("");

    // Pointer-driven drag-select (setupDragSelect, attached once to chartEl)
    // reads this to know which row to highlight/commit — it handles mouse
    // and touch, including a drag that ends on a different row than it
    // started. The plain click listener below is the keyboard fallback
    // (Enter/Space on a focused row fires a real click with detail===0,
    // which pointer events never see) — guarded so a real pointer tap,
    // which pointerup already committed, doesn't fire onClick twice.
    activeRowHandler = { dataAttr, onClick };
    chartEl.querySelectorAll<HTMLButtonElement>(`[data-${dataAttr}]`).forEach((btn) => {
      btn.addEventListener("click", (e) => {
        if ((e as MouseEvent).detail === 0) {
          onClick(Number(btn.dataset[dataAttr === "day-idx" ? "dayIdx" : dataAttr]));
        }
      });
    });
  }

  /** Highlights whatever row is under the pointer while dragging, and
   * commits whichever row the pointer was over at release — so the user
   * can see what they're about to select before letting go. */
  function setupDragSelect(): void {
    let dragging = false;
    let lastRow: HTMLElement | null = null;

    function rowAt(x: number, y: number): HTMLElement | null {
      const el = document.elementFromPoint(x, y) as HTMLElement | null;
      const row = el?.closest<HTMLElement>(".row");
      return row && chartEl.contains(row) ? row : null;
    }

    function setHighlight(row: HTMLElement | null): void {
      if (lastRow && lastRow !== row) lastRow.classList.remove("is-dragging");
      if (row) row.classList.add("is-dragging");
      lastRow = row;
    }

    function endDrag(commit: boolean): void {
      if (!dragging) return;
      dragging = false;
      const row = lastRow;
      setHighlight(null);
      if (commit && row && activeRowHandler) {
        const attr = activeRowHandler.dataAttr === "day-idx" ? "dayIdx" : activeRowHandler.dataAttr;
        const key = Number(row.dataset[attr]);
        activeRowHandler.onClick(key);
      }
    }

    chartEl.addEventListener("pointerdown", (e) => {
      dragging = true;
      setHighlight(rowAt(e.clientX, e.clientY));
    });
    chartEl.addEventListener("pointermove", (e) => {
      if (!dragging) return;
      setHighlight(rowAt(e.clientX, e.clientY));
    });
    chartEl.addEventListener("pointerup", () => endDrag(true));
    chartEl.addEventListener("pointercancel", () => endDrag(false));
  }

  // ---------- range view: 14 day rows ----------

  function renderRangeChart(): void {
    // Scoped to the currently-selected window, not every day the export
    // carries — the peak marker, bar scaling, and preview-cycle divider
    // all mean "within what's on screen right now," the same as they did
    // back when a window was the whole export.
    const days = currentWindowDays();
    const windowOffset = state.windowIdx * state.forecast.windowDays;
    const maxIndex = Math.max(...days.map((d) => d.dayIndex), 1);
    const peakIdx = peakDayIdxInWindow(days);
    const cycleLen = state.forecast.orderCycleDays;

    renderRows(
      days.map((d, i) => ({
        // The global index into forecast.days, not the position within
        // this window slice — jumpToDay/isSelected both compare against
        // state.dayIdx, which is always a global index.
        key: windowOffset + i,
        label: formatDayTitle(d.date),
        value: d.dayIndex,
        isPeak: i === peakIdx,
        isSelected: windowOffset + i === state.dayIdx,
        isPreview: i >= cycleLen,
        tier: dayIndexTier(d.dayIndex, i === peakIdx),
      })),
      maxIndex,
      "day-idx",
      jumpToDay
    );
  }

  // ---------- day view: hour rows ----------

  function renderDayChart(day: Day): void {
    const maxIndex = Math.max(...day.hours.map((h) => h.index), 1);

    renderRows(
      day.hours.map((h) => ({
        key: h.hour,
        label: formatHourRange(h.hour),
        value: h.index,
        isPeak: h.hour === day.peakHour,
        isSelected: h.hour === state.selectedHour,
        isPreview: false,
        sectionLabel: DAYPART_LABELS[h.daypart],
      })),
      maxIndex,
      "hour",
      (hour) => selectHour(state.selectedHour === hour ? null : hour)
    );
  }

  function renderDetailNav(primary: string, secondary: string, prevDisabled: boolean, nextDisabled: boolean): string {
    return `
      <div class="detail__nav">
        <div class="detail__nav-group">
          <button class="detail__nav-btn" id="nav-prev" ${prevDisabled ? "disabled" : ""} aria-label="Previous">‹</button>
          <span class="detail__nav-labels">
            <span class="detail__nav-secondary">${secondary}</span>
            <span class="detail__nav-primary">${primary}</span>
          </span>
          <button class="detail__nav-btn" id="nav-next" ${nextDisabled ? "disabled" : ""} aria-label="Next">›</button>
        </div>
        <button class="detail__close" id="nav-close" aria-label="Close">✕</button>
      </div>
    `;
  }

  // Depth 3's nav trades the hour stepper for the flight's own identity —
  // stepping hours doesn't mean anything while looking at one flight, so
  // the arrows go away and the badge/number/airline take their place. The
  // close button here backs out one level (to the hour), not all the way
  // out to the range view — that is what "Back to flights" used to do.
  function renderFlightNav(f: Flight): string {
    return `
      <div class="detail__nav">
        <div class="detail__nav-group detail__nav-group--flight">
          <span class="flight-nav-id">
            ${airlineBadge(f)}
            <span class="detail__nav-labels detail__nav-labels--flight">
              <span class="detail__nav-secondary">${formatAirlineName(f.airline)}</span>
              <span class="detail__nav-primary">${f.flightNumber}</span>
            </span>
          </span>
          <span class="flight-nav-time">
            <span class="flight-nav-time__value">${formatFlightTime(f.scheduledTime)}</span>
            <span class="flight-row__tag">${f.direction}</span>
          </span>
        </div>
        <button class="detail__close" id="nav-close" aria-label="Back to hour">✕</button>
      </div>
    `;
  }

  function renderDayDetail(day: Day): void {
    const hour = state.selectedHour === null
      ? undefined
      : day.hours.find((h) => h.hour === state.selectedHour);
    const flight = currentFlight();

    if (!hour) {
      detailEl.classList.remove("is-open");
      detailEl.innerHTML = `<div class="detail__body"><p class="empty-hint">Tap an hour to see what is driving it.</p></div>`;
      return;
    }

    detailEl.classList.add("is-open");

    if (flight) {
      detailEl.innerHTML = renderFlightNav(flight) + `<div class="detail__body">${renderFlightDetail(flight)}</div>`;
      detailEl.querySelector("#nav-close")?.addEventListener("click", () => selectFlight(null));
    } else {
      const atStart = hour.hour <= day.openHour;
      const atEnd = hour.hour >= day.closeHour - 1;
      const nav = renderDetailNav(formatHourRange(hour.hour), formatDayTitle(day.date), atStart, atEnd);
      detailEl.innerHTML = nav + `<div class="detail__body">${renderHourSummary(day, hour.hour)}</div>`;
      detailEl.querySelectorAll<HTMLElement>("[data-flight-id]").forEach((row) => {
        row.addEventListener("click", () => selectFlight(Number(row.dataset.flightId)));
        row.addEventListener("keydown", (e) => {
          if ((e as KeyboardEvent).key === "Enter" || (e as KeyboardEvent).key === " ") {
            e.preventDefault();
            selectFlight(Number(row.dataset.flightId));
          }
        });
      });
      detailEl.querySelector("#nav-prev")?.addEventListener("click", () => stepHour(-1));
      detailEl.querySelector("#nav-next")?.addEventListener("click", () => stepHour(1));
      detailEl.querySelector("#nav-close")?.addEventListener("click", () => goToRangeView());
    }
  }

  function renderHourSummary(day: Day, hourNum: number): string {
    const hour = day.hours.find((h) => h.hour === hourNum)!;
    const maxIndex = Math.max(...day.hours.map((h) => h.index), 1);
    const isPeak = hourNum === day.peakHour;
    const tier = demandTier(hour.index / maxIndex, isPeak);

    return `
      <span class="daypart-chip">${DAYPART_LABELS[hour.daypart]}</span>
      <div class="detail__hero-row">
        <div class="detail__hero-text">
          <div class="detail__eyebrow-row">
            <span class="detail__eyebrow">Traffic index</span>
            ${infoTip("trafficIndex", "traffic index")}
          </div>
          <div class="detail__hero">${Math.round(hour.index)}</div>
          <div class="detail__tier" style="color:var(--${tier.className})">${tier.label}</div>
          <div class="detail__caption">Expected foot traffic in front of this location</div>
        </div>
        ${renderGauge(hour.index, maxIndex)}
      </div>
      <div class="section-heading">
        <span>✈ Flights this hour</span>
        <span class="section-heading__count">${hour.flights.length + hour.inferredFlightCount} flight${hour.flights.length + hour.inferredFlightCount === 1 ? "" : "s"}</span>
      </div>
      ${
        hour.flights.length === 0 && hour.inferredFlightCount === 0
          ? `<p class="empty-hint">No scheduled flights this hour.</p>`
          : `${
              hour.flights.length === 0
                ? ""
                : `<table class="flight-table">
              <thead>
                <tr>
                  <th scope="col">Flight</th>
                  <th scope="col">Scheduled</th>
                  <th scope="col">
                    <span class="flight-table__th-label">Pax past ${state.forecast.location.gateLabel}</span>
                    ${infoTip("passengersPastA36", "pax past this gate", "right")}
                  </th>
                </tr>
              </thead>
              <tbody>
                ${hour.flights
                  .map(
                    (f) => `
                  <tr tabindex="0" role="button" data-flight-id="${f.flightId}" aria-label="${f.flightNumber} details">
                    <td>
                      <div class="flight-row__id">
                        ${airlineBadge(f)}
                        <span>
                          ${f.flightNumber}
                          <div class="flight-row__meta">${f.aircraftType}</div>
                        </span>
                      </div>
                    </td>
                    <td>
                      ${formatFlightTime(f.scheduledTime)}
                      <div class="flight-row__tag">${f.direction}</div>
                    </td>
                    <td>${Math.round(f.passengersPastA36)}</td>
                  </tr>
                `
                  )
                  .join("")}
              </tbody>
            </table>`
            }
            ${
              hour.inferredFlightCount === 0
                ? ""
                : `<div class="inferred-flights-note">+ ${hour.inferredFlightCount} flight${hour.inferredFlightCount === 1 ? "" : "s"}, gate not yet assigned (inferred) — ${Math.round(hour.inferredExposure)} pax</div>`
            }`
      }
      <div class="about-card">
        <span class="about-card__icon">ⓘ</span>
        <div>
          <div class="about-card__title">About the traffic index</div>
          <div class="about-card__body">${TERM_INFO.trafficIndex}</div>
        </div>
      </div>
    `;
  }

  function renderFlightDetail(f: Flight): string {
    const { airportCode: homeCode, city: homeCity } = state.forecast.location;
    const [leftCode, leftCity, rightCode, rightCity] =
      f.direction === "departure"
        ? [homeCode, homeCity, f.otherAirportCode, f.otherAirportCity]
        : [f.otherAirportCode, f.otherAirportCity, homeCode, homeCity];

    const lfTier = loadFactorTier(f.loadFactor);
    const gwTier = geometryWeightTier(f.geometryWeight);

    const { avg, max } = flightExposureStats;
    const isAbove = f.passengersPastA36 >= avg;
    const barPct = Math.min(100, (f.passengersPastA36 / max) * 100);
    const avgPct = Math.min(100, (avg / max) * 100);

    return `
      <div class="route-card">
        <div class="route-card__endpoints">
          <div class="route-card__endpoint">
            <div class="route-card__code">${leftCode}</div>
            <div class="route-card__city">${leftCity}</div>
          </div>
          <div class="route-card__path">
            <span class="route-card__line"></span>
            <span class="route-card__plane" aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="currentColor"><path d="M21 16v-2l-8-5V3.5a1.5 1.5 0 0 0-3 0V9l-8 5v2l8-2.5V19l-2.5 1.5V22l4-1 4 1v-1.5L13 19v-5.5l8 2.5z"/></svg>
            </span>
            <span class="route-card__line"></span>
          </div>
          <div class="route-card__endpoint route-card__endpoint--right">
            <div class="route-card__code">${rightCode}</div>
            <div class="route-card__city">${rightCity}</div>
          </div>
        </div>
        ${f.durationMinutes !== null ? `<div class="route-card__duration">${formatDuration(f.durationMinutes)}</div>` : ""}
      </div>

      <div class="stat-mini-row">
        ${
          f.aircraftType !== ""
            ? `<div class="stat-mini">
                <span class="stat-mini__label">${statIcon("aircraft")}Aircraft</span>
                <span class="stat-mini__value">${f.aircraftType}</span>
              </div>`
            : ""
        }
        ${
          f.gate !== ""
            ? `<div class="stat-mini">
                <span class="stat-mini__label">${statIcon("gate")}Gate</span>
                <span class="stat-mini__value">${f.gate}</span>
                <span class="stat-mini__sub">${f.gateZone}</span>
              </div>`
            : ""
        }
        <div class="stat-mini">
          <span class="stat-mini__label">${statIcon("seats")}Seats</span>
          <span class="stat-mini__value">${f.seats}</span>
        </div>
        <div class="stat-mini">
          <span class="stat-mini__label">${statIcon("people")}Load factor ${infoTip("loadFactor", "load factor")}</span>
          <span class="stat-mini__value">${(f.loadFactor * 100).toFixed(0)}%</span>
          <span class="stat-mini__sub" style="color:var(--${lfTier.className})">${lfTier.label}</span>
        </div>
      </div>

      <div class="passenger-card">
        <div class="detail__eyebrow-row">
          <span class="detail__eyebrow">Expected passengers past ${state.forecast.location.gateLabel}</span>
          ${infoTip("passengersPastA36", "passengers past this gate")}
        </div>
        <div class="passenger-card__row">
          <div class="passenger-card__value">${f.passengersPastA36.toFixed(1)}</div>
          <div class="passenger-card__avg">
            <div class="stat-mini__label">Avg per flight</div>
            <div class="passenger-card__avg-value">${avg.toFixed(1)}</div>
          </div>
        </div>
        <div class="passenger-card__track">
          <span class="passenger-card__fill" style="width:${barPct}%"></span>
          <span class="passenger-card__avg-marker" style="left:${avgPct}%"></span>
        </div>
        <span class="passenger-card__chip${isAbove ? "" : " is-below"}">${isAbove ? "Above average" : "Below average"}</span>
      </div>

      <div class="stat-mini-row">
        <div class="stat-mini">
          <span class="stat-mini__label">${statIcon("scale")}Geometry weight ${infoTip("geometryWeight", "geometry weight")}</span>
          <span class="stat-mini__value">${f.geometryWeight.toFixed(2)}</span>
          <span class="stat-mini__sub" style="color:var(--${gwTier.className})">${gwTier.label}</span>
        </div>
        <div class="stat-mini">
          <span class="stat-mini__label">${statIcon("trend")}Traffic contribution</span>
          <span class="stat-mini__value">${f.passengersPastA36.toFixed(1)}</span>
          <span class="stat-mini__sub">index points</span>
        </div>
        <div class="stat-mini">
          <span class="stat-mini__label">${statIcon("clock")}Impact window</span>
          <span class="stat-mini__value">${formatFlightTime(f.impactWindowStart)}</span>
          <span class="stat-mini__value">${formatFlightTime(f.impactWindowEnd)}</span>
        </div>
      </div>

      <div class="about-card">
        <span class="about-card__icon">ⓘ</span>
        <div class="about-card__body">This flight is expected to contribute ${isAbove ? "above" : "below"}-average foot traffic in front of ${state.forecast.location.displayName}, based on its scheduled time and gate location.</div>
      </div>
    `;
  }

  // ---------- footer ----------

  function renderFooter(): void {
    const generated = new Date(
      state.forecast.generatedAt.endsWith("Z")
        ? state.forecast.generatedAt
        : `${state.forecast.generatedAt}Z`
    );
    const isStale = Date.now() - generated.getTime() > STALE_THRESHOLD_MS;
    footerEl.classList.toggle("is-stale", isStale);
    // "Baseline", not "assumed" — the per-flight load factor shown in the
    // drill-down is this number adjusted by season and daypart, and can
    // visibly differ from it (a July dinner flight runs closer to 90%).
    // Calling the baseline itself "assumed" implied it was the one number
    // used everywhere, which isn't true and was an easy thing to catch by
    // comparing this line to any individual flight's own stat.
    footerEl.innerHTML = `<span aria-hidden="true">🕐</span> Generated ${formatGeneratedAt(state.forecast.generatedAt)} · Load factor ${Math.round(state.forecast.defaultLoadFactor * 100)}% baseline`;
  }

  // ---------- top-level dispatch ----------

  function render(): void {
    mainEl.classList.toggle("main--full", state.view === "range");
    renderStatCard();
    renderBreadcrumb();
    renderChartHeader();
    if (state.view === "range") {
      renderRangeChart();
    } else {
      const day = currentDay()!;
      renderDayChart(day);
      renderDayDetail(day);
    }
    renderFooter();
  }

  setupDragSelect();
  render();
}
