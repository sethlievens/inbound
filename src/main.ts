import "./styles/base.css";
import { fetchForecast, fetchLocationManifest } from "./lib/data";
import { mount } from "./app";
import { showLoadingScreen } from "./loading";
import type { LocationManifestEntry } from "./lib/types";

const root = document.querySelector<HTMLDivElement>("#app")!;

function showLoadError(detail: string): void {
  root.innerHTML = `
    <div style="padding:2rem;">
      <p class="breadcrumb__title">Can't load the forecast.</p>
      <p class="empty-hint">${detail}</p>
    </div>
  `;
}

// Re-invoked whenever the user picks a different location from the picker
// (see app.ts) — a location switch is just loading a different small
// static file, the same one-time fetch-and-mount flow as the initial
// page load, not a special case.
async function loadLocation(forecastFile: string, locations: LocationManifestEntry[]): Promise<void> {
  const loading = showLoadingScreen(root);
  try {
    const forecast = await fetchForecast(forecastFile, (pct) => loading.setProgress(pct));
    loading.destroy();
    mount(root, forecast, locations, (nextFile) => loadLocation(nextFile, locations));
  } catch (err) {
    loading.destroy();
    console.error(err);
    showLoadError(`public/data/forecast-${forecastFile}.json didn't load. Check that the file exists and the dev server is serving it.`);
  }
}

fetchLocationManifest()
  .then((locations) => {
    if (locations.length === 0) throw new Error("locations.json was empty");
    // Manifest is ordered by LocationId, so the first entry is always the
    // original DTW A36 location — a stable, predictable default rather
    // than an arbitrary one.
    return loadLocation(locations[0].forecastFile, locations);
  })
  .catch((err) => {
    console.error(err);
    showLoadError("public/data/locations.json didn't load. Check that the file exists and the dev server is serving it.");
  });
