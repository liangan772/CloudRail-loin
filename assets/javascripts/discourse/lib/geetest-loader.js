const GT4_SCRIPT_URL = "https://static.geetest.com/v4/gt4.js";

let loadPromise = null;

/**
 * Loads gt4.js exactly once and resolves with the global `initGeetest4`.
 *
 * The official docs recommend either loading gt4.js from GeeTest's CDN
 * or self-hosting it for better stability. If you self-host, pass your
 * own same-origin URL as `scriptUrl`; the default points at the CDN.
 */
export default function loadGeetest(scriptUrl = GT4_SCRIPT_URL) {
  if (window.initGeetest4) {
    return Promise.resolve(window.initGeetest4);
  }

  if (loadPromise) {
    return loadPromise;
  }

  loadPromise = new Promise((resolve, reject) => {
    const existing = document.querySelector(`script[src="${scriptUrl}"]`);

    const onLoad = () => {
      if (window.initGeetest4) {
        resolve(window.initGeetest4);
      } else {
        reject(new Error("gt4.js loaded but initGeetest4 is unavailable"));
      }
    };

    if (existing) {
      existing.addEventListener("load", onLoad, { once: true });
      existing.addEventListener(
        "error",
        () => reject(new Error("failed to load gt4.js")),
        { once: true },
      );
      return;
    }

    const script = document.createElement("script");
    script.src = scriptUrl;
    script.async = true;
    script.defer = true;
    script.onload = onLoad;
    script.onerror = () => {
      loadPromise = null;
      reject(new Error("failed to load gt4.js"));
    };
    document.head.appendChild(script);
  });

  return loadPromise;
}

export { GT4_SCRIPT_URL };
