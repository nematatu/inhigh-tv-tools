(() => {
  "use strict";

  const DEFAULT_SETTINGS = Object.freeze({
    skipSeconds: 10,
    keyboardEnabled: true,
  });
  const MIN_SKIP_SECONDS = 1;
  const MAX_SKIP_SECONDS = 300;

  let settings = { ...DEFAULT_SETTINGS };
  let scanScheduled = false;
  const feedbackTimers = new WeakMap();

  function normalizeSeconds(value) {
    const parsed = Number.parseInt(String(value), 10);
    if (!Number.isFinite(parsed)) {
      return DEFAULT_SETTINGS.skipSeconds;
    }
    return Math.min(MAX_SKIP_SECONDS, Math.max(MIN_SKIP_SECONDS, parsed));
  }

  function applyStoredSettings(stored) {
    settings = {
      skipSeconds: normalizeSeconds(stored.skipSeconds),
      keyboardEnabled:
        typeof stored.keyboardEnabled === "boolean"
          ? stored.keyboardEnabled
          : DEFAULT_SETTINGS.keyboardEnabled,
    };
    updateButtonLabels();
  }

  function loadSettings() {
    chrome.storage.sync.get(DEFAULT_SETTINGS, (stored) => {
      if (chrome.runtime.lastError) {
        applyStoredSettings(DEFAULT_SETTINGS);
        return;
      }
      applyStoredSettings(stored);
    });
  }

  function getPlayerVideo(player) {
    return (
      player.querySelector(":scope > video.vjs-tech") ||
      player.querySelector("video.vjs-tech")
    );
  }

  function isVisible(element) {
    if (!(element instanceof Element)) {
      return false;
    }
    const rect = element.getBoundingClientRect();
    const style = window.getComputedStyle(element);
    return (
      rect.width > 0 &&
      rect.height > 0 &&
      style.display !== "none" &&
      style.visibility !== "hidden"
    );
  }

  function isAdvertisementPlaying(player) {
    const adLayer = player.querySelector(":scope > .strp-ads.strp-is-linearad");
    return Boolean(adLayer && isVisible(adLayer));
  }

  function createArrowIcon() {
    return `
      <svg class="inhigh-skip-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
        <path d="M12 4.25V1.5L7.4 5.8l4.6 4.3V7.25a6.25 6.25 0 1 1-5.66 8.9l-2.17.99A8.65 8.65 0 1 0 12 4.25Z"></path>
      </svg>
      <span class="inhigh-skip-seconds" aria-hidden="true"></span>
    `;
  }

  function updateButtonLabel(button) {
    const direction = Number(button.dataset.inhighSkipDirection);
    const action = direction < 0 ? "戻る" : "進む";
    const key = direction < 0 ? "←" : "→";
    const label = `${settings.skipSeconds}秒${action}（${key}）`;
    if (button.title !== label) {
      button.title = label;
    }
    if (button.getAttribute("aria-label") !== label) {
      button.setAttribute("aria-label", label);
    }
    const seconds = button.querySelector(".inhigh-skip-seconds");
    if (seconds && seconds.textContent !== String(settings.skipSeconds)) {
      seconds.textContent = String(settings.skipSeconds);
    }
  }

  function updateButtonLabels() {
    document.querySelectorAll(".inhigh-skip-button").forEach(updateButtonLabel);
  }

  function showFeedback(player, direction, actualSeconds) {
    let feedback = player.querySelector(":scope > .inhigh-skip-feedback");
    if (!feedback) {
      feedback = document.createElement("div");
      feedback.className = "inhigh-skip-feedback";
      feedback.setAttribute("aria-live", "polite");
      player.append(feedback);
    }

    const previousTimer = feedbackTimers.get(player);
    if (previousTimer) {
      window.clearTimeout(previousTimer);
    }

    feedback.classList.remove(
      "inhigh-skip-feedback--backward",
      "inhigh-skip-feedback--forward",
      "is-visible",
    );
    feedback.classList.add(
      direction < 0
        ? "inhigh-skip-feedback--backward"
        : "inhigh-skip-feedback--forward",
    );
    feedback.textContent = `${direction < 0 ? "↶" : "↷"} ${Math.round(actualSeconds)}秒`;

    // 同じ方向を連続操作したときもアニメーションを再実行します。
    void feedback.offsetWidth;
    feedback.classList.add("is-visible");

    const timer = window.setTimeout(() => {
      feedback.classList.remove("is-visible");
      feedbackTimers.delete(player);
    }, 650);
    feedbackTimers.set(player, timer);
  }

  function seekPlayer(player, direction) {
    const video = getPlayerVideo(player);
    if (!video || isAdvertisementPlaying(player)) {
      return false;
    }

    const duration = Number(video.duration);
    const currentTime = Number(video.currentTime);
    if (!Number.isFinite(duration) || duration <= 0 || !Number.isFinite(currentTime)) {
      return false;
    }

    const requestedDelta = settings.skipSeconds * direction;
    const targetTime = Math.min(duration, Math.max(0, currentTime + requestedDelta));
    const actualSeconds = Math.abs(targetTime - currentTime);
    if (actualSeconds < 0.01) {
      return false;
    }

    try {
      video.currentTime = targetTime;
      showFeedback(player, direction, actualSeconds);
      return true;
    } catch (_error) {
      return false;
    }
  }

  function togglePlayback(player) {
    const video = getPlayerVideo(player);
    if (!video || isAdvertisementPlaying(player)) {
      return false;
    }

    try {
      if (video.paused || video.ended) {
        const playResult = video.play();
        if (playResult && typeof playResult.catch === "function") {
          playResult.catch(() => {});
        }
      } else {
        video.pause();
      }
      return true;
    } catch (_error) {
      return false;
    }
  }

  function createSkipButton(player, direction) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = [
      "inhigh-skip-button",
      direction < 0 ? "inhigh-skip-button--backward" : "inhigh-skip-button--forward",
      "vjs-control",
      "vjs-button",
    ].join(" ");
    button.dataset.inhighSkipDirection = String(direction);
    button.setAttribute("aria-keyshortcuts", direction < 0 ? "ArrowLeft" : "ArrowRight");
    button.innerHTML = createArrowIcon();
    updateButtonLabel(button);
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      seekPlayer(player, direction);
    });
    return button;
  }

  function installControls(player) {
    const video = getPlayerVideo(player);
    const leftControls = player.querySelector(
      ":scope > .vjs-chrome-bottom .vjs-chrome-controls .vjs-left-controls",
    );
    if (!video || !leftControls) {
      return;
    }

    const existing = leftControls.querySelectorAll(":scope > .inhigh-skip-button");
    if (existing.length === 2) {
      existing.forEach(updateButtonLabel);
      return;
    }
    existing.forEach((button) => button.remove());

    const playButton = leftControls.querySelector(":scope > .vjs-play-control");
    if (!playButton) {
      return;
    }

    const backwardButton = createSkipButton(player, -1);
    const forwardButton = createSkipButton(player, 1);
    playButton.after(backwardButton, forwardButton);
  }

  function scanPlayers() {
    scanScheduled = false;
    document.querySelectorAll(".video-js").forEach(installControls);
  }

  function schedulePlayerScan() {
    if (scanScheduled) {
      return;
    }
    scanScheduled = true;
    window.requestAnimationFrame(scanPlayers);
  }

  function findActivePlayer() {
    const fullscreenElement = document.fullscreenElement;
    if (fullscreenElement) {
      const fullscreenPlayer = fullscreenElement.matches?.(".video-js")
        ? fullscreenElement
        : fullscreenElement.closest?.(".video-js");
      if (fullscreenPlayer && getPlayerVideo(fullscreenPlayer)) {
        return fullscreenPlayer;
      }
    }

    const candidates = Array.from(document.querySelectorAll(".video-js"))
      .filter((player) => {
        const video = getPlayerVideo(player);
        return video && isVisible(video) && !isAdvertisementPlaying(player);
      })
      .map((player) => {
        const rect = player.getBoundingClientRect();
        return { player, area: rect.width * rect.height };
      })
      .sort((a, b) => b.area - a.area);

    return candidates[0]?.player || null;
  }

  function isTypingOrNavigatingControls(target) {
    if (!(target instanceof Element)) {
      return false;
    }
    return Boolean(
      target.closest(
        "input, textarea, select, [contenteditable]:not([contenteditable='false']), " +
          "[role='slider'], [role='menu'], [role='menuitem'], .vjs-settings-menu, .vjs-menu",
      ),
    );
  }

  function handleKeydown(event) {
    const isArrowKey = event.key === "ArrowLeft" || event.key === "ArrowRight";
    const isSpaceKey =
      event.code === "Space" || event.key === " " || event.key === "Spacebar";
    if (
      !settings.keyboardEnabled ||
      event.defaultPrevented ||
      event.altKey ||
      event.ctrlKey ||
      event.metaKey ||
      event.shiftKey ||
      (!isArrowKey && !isSpaceKey) ||
      (isSpaceKey && event.repeat) ||
      isTypingOrNavigatingControls(event.target)
    ) {
      return;
    }

    const player = findActivePlayer();
    if (!player) {
      return;
    }

    const handled = isSpaceKey
      ? togglePlayback(player)
      : seekPlayer(player, event.key === "ArrowLeft" ? -1 : 1);
    if (handled) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }

  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName !== "sync") {
      return;
    }
    applyStoredSettings({
      skipSeconds: changes.skipSeconds?.newValue ?? settings.skipSeconds,
      keyboardEnabled: changes.keyboardEnabled?.newValue ?? settings.keyboardEnabled,
    });
  });

  const observer = new MutationObserver(schedulePlayerScan);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener("keydown", handleKeydown, true);

  loadSettings();
  schedulePlayerScan();
})();
