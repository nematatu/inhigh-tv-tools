(() => {
  "use strict";

  const DEFAULT_SETTINGS = Object.freeze({
    skipSeconds: 10,
    keyboardEnabled: true,
  });
  const MIN_SKIP_SECONDS = 1;
  const MAX_SKIP_SECONDS = 300;

  const form = document.querySelector("#settings-form");
  const secondsInput = document.querySelector("#skip-seconds");
  const keyboardInput = document.querySelector("#keyboard-enabled");
  const resetButton = document.querySelector("#reset-button");
  const status = document.querySelector("#status");
  let statusTimer = null;

  function normalizeSeconds(value) {
    const parsed = Number.parseInt(String(value), 10);
    if (!Number.isFinite(parsed)) {
      return DEFAULT_SETTINGS.skipSeconds;
    }
    return Math.min(MAX_SKIP_SECONDS, Math.max(MIN_SKIP_SECONDS, parsed));
  }

  function render(settings) {
    secondsInput.value = String(normalizeSeconds(settings.skipSeconds));
    keyboardInput.checked = Boolean(settings.keyboardEnabled);
  }

  function showStatus(message, isError = false) {
    if (statusTimer) {
      window.clearTimeout(statusTimer);
    }
    status.textContent = message;
    status.classList.toggle("error", isError);
    statusTimer = window.setTimeout(() => {
      status.textContent = "";
      status.classList.remove("error");
    }, 2200);
  }

  function loadSettings() {
    chrome.storage.sync.get(DEFAULT_SETTINGS, (stored) => {
      if (chrome.runtime.lastError) {
        render(DEFAULT_SETTINGS);
        showStatus("設定を読み込めませんでした", true);
        return;
      }
      render(stored);
    });
  }

  function saveSettings(event) {
    event.preventDefault();
    if (!form.reportValidity()) {
      return;
    }

    const nextSettings = {
      skipSeconds: normalizeSeconds(secondsInput.value),
      keyboardEnabled: keyboardInput.checked,
    };
    render(nextSettings);
    chrome.storage.sync.set(nextSettings, () => {
      if (chrome.runtime.lastError) {
        showStatus("保存できませんでした", true);
        return;
      }
      showStatus("保存しました");
    });
  }

  document.querySelectorAll(".preset").forEach((button) => {
    button.addEventListener("click", () => {
      secondsInput.value = button.dataset.seconds;
      secondsInput.focus();
    });
  });

  resetButton.addEventListener("click", () => {
    render(DEFAULT_SETTINGS);
    chrome.storage.sync.set(DEFAULT_SETTINGS, () => {
      if (chrome.runtime.lastError) {
        showStatus("初期値を保存できませんでした", true);
        return;
      }
      showStatus("10秒に戻しました");
    });
  });

  form.addEventListener("submit", saveSettings);
  loadSettings();
})();
