// A loading screen, not a spinner — the artifact is a few MB with live
// data, so worth showing real download progress rather than pretending
// there's nothing to wait for. Messages rotate independently of progress
// (they're flavor, not a second progress signal) and lean into the
// flight-schedule framing the rest of the app already uses.

const MESSAGES = [
  "Requesting clearance for descent...",
  "Extending landing gear...",
  "Taxiing data to the gate...",
  "Compiling passenger manifests...",
  "Cross-referencing gate assignments...",
  "Calculating dwell curves...",
  "Reading the departure board...",
  "Spooling up the exposure model...",
  "Checking in the last few flights...",
  "Final approach...",
];

export interface LoadingScreen {
  setProgress(pct: number): void;
  destroy(): void;
}

export function showLoadingScreen(root: HTMLElement): LoadingScreen {
  root.innerHTML = `
    <div class="loading-screen">
      <img class="loading-screen__mark" src="/inbound-mark.png" alt="Inbound" />
      <div class="loading-screen__track">
        <div class="loading-screen__fill" id="loading-fill" style="width:4%"></div>
      </div>
      <div class="loading-screen__pct" id="loading-pct">0%</div>
      <div class="loading-screen__message" id="loading-message">${MESSAGES[0]}</div>
    </div>
  `;

  const fillEl = root.querySelector<HTMLElement>("#loading-fill")!;
  const pctEl = root.querySelector<HTMLElement>("#loading-pct")!;
  const msgEl = root.querySelector<HTMLElement>("#loading-message")!;

  let msgIdx = 0;
  const intervalId = window.setInterval(() => {
    msgIdx = (msgIdx + 1) % MESSAGES.length;
    msgEl.textContent = MESSAGES[msgIdx];
  }, 1400);

  return {
    setProgress(pct: number) {
      const clamped = Math.max(4, Math.min(100, pct));
      fillEl.style.width = `${clamped}%`;
      pctEl.textContent = `${Math.round(clamped)}%`;
    },
    destroy() {
      window.clearInterval(intervalId);
    },
  };
}
