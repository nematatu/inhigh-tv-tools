(() => {
  "use strict";

  const listeners = [];
  window.chrome = {
    runtime: { lastError: null },
    storage: {
      sync: {
        get(defaults, callback) {
          callback({ ...defaults, skipSeconds: 10, keyboardEnabled: true });
        },
        set(_settings, callback) {
          callback?.();
        },
      },
      onChanged: {
        addListener(listener) {
          listeners.push(listener);
        },
      },
    },
  };

  Object.defineProperties(HTMLMediaElement.prototype, {
    duration: {
      configurable: true,
      get() {
        return 600;
      },
    },
    currentTime: {
      configurable: true,
      get() {
        return Number(this.dataset.mockCurrentTime ?? 100);
      },
      set(value) {
        this.dataset.mockCurrentTime = String(Number(value));
      },
    },
  });

  const video = document.querySelector("video.vjs-tech");
  video.dataset.mockCurrentTime = "100";

  document.querySelector("#set-five-seconds").addEventListener("click", () => {
    listeners.forEach((listener) => {
      listener({ skipSeconds: { newValue: 5 } }, "sync");
    });
  });

  window.__inhighHarness = {
    video,
    listeners,
    result: document.querySelector("#test-result"),
  };
})();
