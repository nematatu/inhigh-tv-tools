(() => {
  "use strict";

  const startValue = new URLSearchParams(window.location.search).get("start");
  const requestedSeconds = Number(startValue);
  const MAX_SECONDS = 24 * 60 * 60;
  const watchedVideos = new WeakSet();
  const appliedVideos = new WeakSet();
  const timers = new WeakMap();

  if (
    startValue === null ||
    startValue.trim() === "" ||
    !Number.isFinite(requestedSeconds) ||
    requestedSeconds < 0 ||
    requestedSeconds > MAX_SECONDS
  ) {
    return;
  }

  function isVisible(element) {
    if (!(element instanceof Element)) {
      return false;
    }
    const rect = element.getBoundingClientRect();
    const style = window.getComputedStyle(element);
    return rect.width > 0 && rect.height > 0 && style.display !== "none" && style.visibility !== "hidden";
  }

  function isAdvertisementPlaying(player) {
    return Boolean(
      player.querySelector(":scope > .strp-ads.strp-is-linearad") &&
        isVisible(player.querySelector(":scope > .strp-ads.strp-is-linearad")),
    );
  }

  function stopTimer(video) {
    const timer = timers.get(video);
    if (timer) {
      window.clearInterval(timer);
      timers.delete(video);
    }
  }

  function notice(text) {
    const existing = document.querySelector(".inhigh-deeplink-notice");
    existing?.remove();
    const element = document.createElement("div");
    element.className = "inhigh-deeplink-notice";
    element.textContent = text;
    document.body.append(element);
    window.setTimeout(() => element.remove(), 3500);
  }

  function attempt(player, video) {
    if (appliedVideos.has(video) || !video.isConnected || isAdvertisementPlaying(player)) {
      return;
    }
    const duration = Number(video.duration);
    if (!Number.isFinite(duration) || duration <= 0 || video.readyState < 1) {
      return;
    }
    const target = Math.min(requestedSeconds, duration);
    try {
      video.currentTime = target;
      appliedVideos.add(video);
      stopTimer(video);
      notice(`試合開始位置 ${Math.floor(target)}秒へ移動しました`);
    } catch (_error) {
      // メタデータ・広告終了後に再試行します。
    }
  }

  function watch(player, video) {
    if (!video || watchedVideos.has(video)) {
      return;
    }
    watchedVideos.add(video);
    const run = () => attempt(player, video);
    ["loadedmetadata", "durationchange", "canplay", "playing", "timeupdate"].forEach((name) => {
      video.addEventListener(name, run);
    });
    const timer = window.setInterval(run, 500);
    timers.set(video, timer);
    run();
    window.setTimeout(() => {
      if (!appliedVideos.has(video)) {
        stopTimer(video);
      }
    }, 120000);
  }

  function scan() {
    document.querySelectorAll(".video-js").forEach((player) => {
      const video = player.querySelector("video.vjs-tech, video");
      watch(player, video);
    });
  }

  const observer = new MutationObserver(scan);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  scan();
})();
