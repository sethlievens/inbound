// Formatting is deliberately dumb: it renders values already computed in SQL,
// it never derives new ones (no re-deriving daypart, no re-averaging index).

const DOW_ABBR = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTH_ABBR = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/** "date" is a plain YYYY-MM-DD string from the artifact — parse as local, not UTC. */
function parseDateOnly(date: string): Date {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(y, m - 1, d);
}

export function formatDayTitle(date: string): string {
  const d = parseDateOnly(date);
  return `${DOW_ABBR[d.getDay()]} ${MONTH_ABBR[d.getMonth()]} ${d.getDate()}`;
}

/** Compact form for narrow bar labels, e.g. "Sat 18". */
export function formatDayShort(date: string): string {
  const d = parseDateOnly(date);
  return `${DOW_ABBR[d.getDay()]} ${d.getDate()}`;
}

/** e.g. "Jul 18 – Jul 31" for the breadcrumb's window label. */
export function formatDateRange(startDate: string, endDate: string): string {
  const a = parseDateOnly(startDate);
  const b = parseDateOnly(endDate);
  return `${MONTH_ABBR[a.getMonth()]} ${a.getDate()} – ${MONTH_ABBR[b.getMonth()]} ${b.getDate()}`;
}

export function formatHourRange(hour: number): string {
  const from = formatHour12(hour);
  const to = formatHour12((hour + 1) % 24);
  return `${from}–${to}`;
}

export function formatHour12(hour: number): string {
  const h = hour % 24;
  const period = h < 12 ? "am" : "pm";
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}${period}`;
}

export function formatFlightTime(iso: string): string {
  // "2026-07-18T06:10:00" -> "6:10 AM"
  const [, time] = iso.split("T");
  const [hStr, mStr] = time.split(":");
  const h = Number(hStr);
  const period = h < 12 ? "AM" : "PM";
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${mStr} ${period}`;
}

export interface DemandTier {
  label: string;
  className: string;
}

/** Buckets an index value into a readable tier, relative to the current
 * view's own peak (not an absolute scale) — a quiet day's busiest hour and
 * a heavy day's busiest hour both read as "Peak" for that view, which is
 * the honest comparison to make since 100 is a fixed baseline but "how
 * busy relative to the rest of this window" is what a bar chart shows. */
export function demandTier(ratio: number, isPeak: boolean): DemandTier {
  if (isPeak) return { label: "Peak", className: "tier-peak" };
  if (ratio >= 0.85) return { label: "Very high demand", className: "tier-very-high" };
  if (ratio >= 0.65) return { label: "High demand", className: "tier-high" };
  if (ratio >= 0.4) return { label: "Moderate demand", className: "tier-moderate" };
  if (ratio >= 0.2) return { label: "Low demand", className: "tier-low" };
  return { label: "Very low demand", className: "tier-very-low" };
}

export function formatDuration(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m}m`;
  return `${h}h ${m}m`;
}

/** Thresholds are ours, not lifted from any reference — chosen so the
 * range of values this dataset actually produces (load factor ~0.80-0.90,
 * geometry weight 0.20-0.85) spreads across all three tiers instead of
 * bunching into one. */
export function loadFactorTier(lf: number): DemandTier {
  if (lf >= 0.85) return { label: "High", className: "tier-high" };
  if (lf >= 0.75) return { label: "Medium", className: "tier-moderate" };
  return { label: "Low", className: "tier-low" };
}

export function geometryWeightTier(w: number): DemandTier {
  if (w >= 0.75) return { label: "High", className: "tier-high" };
  if (w >= 0.45) return { label: "Medium", className: "tier-moderate" };
  return { label: "Low", className: "tier-low" };
}

export function formatGeneratedAt(iso: string): string {
  const d = new Date(iso.endsWith("Z") ? iso : `${iso}Z`);
  const y = d.getUTCFullYear();
  const mo = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  return `${y}-${mo}-${day} ${hh}:${mm} UTC`;
}
