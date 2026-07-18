// Semicircle gauge, purely presentational — a second reading of the same
// index value already shown as the hero number, styled after the dial in
// the reference mockup. Ticks mark 0, the midpoint, and the view's own max
// (rounded up), never an absolute scale, since the index has no fixed
// ceiling — see demandTier's comment on relative-to-view tiering.
//
// The value + "of {max}+" readout renders as an HTML overlay centered in
// the dome rather than SVG <text>, so it can share the page's font and
// tabular-nums setting instead of fighting SVG's separate text stack.

function polar(cx: number, cy: number, r: number, angleDeg: number): { x: number; y: number } {
  const rad = (angleDeg * Math.PI) / 180;
  return { x: cx + r * Math.cos(rad), y: cy - r * Math.sin(rad) };
}

function arcPath(cx: number, cy: number, r: number, fromDeg: number, toDeg: number): string {
  const p0 = polar(cx, cy, r, fromDeg);
  const p1 = polar(cx, cy, r, toDeg);
  const largeArc = fromDeg - toDeg > 180 ? 1 : 0;
  return `M ${p0.x.toFixed(2)} ${p0.y.toFixed(2)} A ${r} ${r} 0 ${largeArc} 1 ${p1.x.toFixed(2)} ${p1.y.toFixed(2)}`;
}

export function renderGauge(value: number, max: number): string {
  const ratio = max > 0 ? Math.min(1, value / max) : 0;
  const cx = 135;
  const cy = 120;
  const r = 74;
  // Ticks need clearance from the arc's own stroke (outer edge at r + half
  // the 14px stroke width, so r + 7 = 81) and from the viewBox's top edge
  // at the midpoint tick, where legible text (see .gauge__tick) is tall
  // enough that both matter. cy moved down and the viewBox grew taller
  // (below) to open up real headroom above the arc for that.
  //
  // The bigger source of overlap wasn't radius at all, though: the side
  // ticks' text-anchor used to point the wrong way, so "0" and the max
  // label grew back in *toward* the arc from their anchor point instead
  // of away from it. Anchoring "0" at its end and the max label at its
  // start (below) means both grow away from the arc — but that only works
  // if there's actually room on the *outside* to grow into. The max label
  // ("178+", four characters) was getting hard-clipped by the viewBox's
  // own right edge, because the side ticks' anchor points sat only ~5
  // units from it. cx moved right and the viewBox grew wider (below) to
  // give ~40 units of clearance on each side — enough for a label several
  // characters longer than anything this dataset actually produces.
  const tickR = r + 21;
  const trackPath = arcPath(cx, cy, r, 180, 0);
  const fillPath = arcPath(cx, cy, r, 180, 180 - 180 * ratio);
  const startTick = polar(cx, cy, tickR, 178);
  const midTick = polar(cx, cy, tickR, 90);
  const endTick = polar(cx, cy, tickR, 2);

  return `
    <div class="gauge-wrap">
      <svg class="gauge" viewBox="0 0 270 134" role="img" aria-label="Gauge: ${Math.round(value)} of ${Math.round(max)}">
        <path class="gauge__track" d="${trackPath}" fill="none" stroke-width="14" stroke-linecap="round" />
        <path class="gauge__fill" d="${fillPath}" fill="none" stroke-width="14" stroke-linecap="round" />
        <text class="gauge__tick" x="${startTick.x.toFixed(1)}" y="${startTick.y.toFixed(1)}" text-anchor="end">0</text>
        <text class="gauge__tick" x="${midTick.x.toFixed(1)}" y="${midTick.y.toFixed(1)}" text-anchor="middle">${Math.round(max / 2)}</text>
        <text class="gauge__tick" x="${endTick.x.toFixed(1)}" y="${endTick.y.toFixed(1)}" text-anchor="start">${Math.round(max)}+</text>
      </svg>
      <div class="gauge__readout">
        <div class="gauge__readout-value">${Math.round(value)}</div>
        <div class="gauge__readout-caption">of ${Math.round(max)}+</div>
      </div>
    </div>
  `;
}
