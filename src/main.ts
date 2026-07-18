import "./styles/base.css";
import { fetchForecast } from "./lib/data";
import { mount } from "./app";
import { showLoadingScreen } from "./loading";

const root = document.querySelector<HTMLDivElement>("#app")!;

const loading = showLoadingScreen(root);

fetchForecast((pct) => loading.setProgress(pct))
  .then((forecast) => {
    loading.destroy();
    mount(root, forecast);
  })
  .catch((err) => {
    loading.destroy();
    console.error(err);
    root.innerHTML = `
      <div style="padding:2rem;">
        <p class="breadcrumb__title">Can't load the forecast.</p>
        <p class="empty-hint">public/data/forecast.json didn't load. Check that the file exists and the dev server is serving it.</p>
      </div>
    `;
  });
