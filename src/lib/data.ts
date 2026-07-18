import type { Forecast } from "./types";

/** Streams the response so progress reflects real bytes downloaded (the
 * artifact is several MB with live data) rather than a fake animated bar.
 * Falls back to a plain fetch if the server doesn't send Content-Length or
 * the browser can't stream the body — still correct, just no progress. */
export async function fetchForecast(onProgress?: (pct: number) => void): Promise<Forecast> {
  const res = await fetch("/data/forecast.json");
  if (!res.ok) {
    throw new Error(`forecast.json request failed: ${res.status}`);
  }

  const total = Number(res.headers.get("Content-Length") ?? 0);
  if (!res.body || !total) {
    const data = (await res.json()) as Forecast;
    onProgress?.(100);
    return data;
  }

  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.length;
    onProgress?.(Math.min(100, Math.round((received / total) * 100)));
  }

  const text = await new Blob(chunks as BlobPart[]).text();
  return JSON.parse(text) as Forecast;
}
