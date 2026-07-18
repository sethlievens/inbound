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
  const cx = 100;
  const cy = 108;
  const r = 74;
  // Ticks sit outside the arc; leaving 24px of headroom above the arc's
  // topmost point keeps the midpoint tick's text from clipping the top
  // edge of the viewBox — the bug in the previous version.
  const tickR = r + 16;
  const trackPath = arcPath(cx, cy, r, 180, 0);
  const fillPath = arcPath(cx, cy, r, 180, 180 - 180 * ratio);
  const startTick = polar(cx, cy, tickR, 178);
  const midTick = polar(cx, cy, tickR, 90);
  const endTick = polar(cx, cy, tickR, 2);

  return `
    <div class="gauge-wrap">
      <svg class="gauge" viewBox="0 0 200 122" role="img" aria-label="Gauge: ${Math.round(value)} of ${Math.round(max)}">
        <path class="gauge__track" d="${trackPath}" fill="none" stroke-width="14" stroke-linecap="round" />
        <path class="gauge__fill" d="${fillPath}" fill="none" stroke-width="14" stroke-linecap="round" />
        <text class="gauge__tick" x="${startTick.x.toFixed(1)}" y="${startTick.y.toFixed(1)}" text-anchor="start">0</text>
        <text class="gauge__tick" x="${midTick.x.toFixed(1)}" y="${midTick.y.toFixed(1)}" text-anchor="middle">${Math.round(max / 2)}</text>
        <text class="gauge__tick" x="${endTick.x.toFixed(1)}" y="${endTick.y.toFixed(1)}" text-anchor="end">${Math.round(max)}+</text>
      </svg>
      <div class="gauge__readout">
        <div class="gauge__readout-value">${Math.round(value)}</div>
        <div class="gauge__readout-caption">of ${Math.round(max)}+</div>
      </div>
    </div>
  `;
}
