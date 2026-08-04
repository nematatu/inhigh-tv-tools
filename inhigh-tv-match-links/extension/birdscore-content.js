(() => {
  "use strict";

  const DATA_PATH = "data/matches.json";
  const MATCH_NO_PATTERN = /\b(?:BT|GT|BS|GS|BD|GD|MS|WS|MD|WD)-\d+\b/;
  const ORDER_PATTERN = /\b(?:D1|D2|S1|S2|S3)\b/;
  const seen = new WeakSet();
  let entries = [];
  let loaded = false;
  let scanScheduled = false;

  function pageKind() {
    return /interhigh-2026-wakayama-Individual/i.test(window.location.pathname)
      ? "individual"
      : "team";
  }

  function normalize(text) {
    return String(text || "").replace(/\s+/g, " ").trim();
  }

  function findMatchNo(text) {
    return normalize(text).match(MATCH_NO_PATTERN)?.[0] || "";
  }

  function findOrderName(text) {
    return normalize(text).match(ORDER_PATTERN)?.[0] || "";
  }

  function makeKey(entry) {
    return `${entry.tournamentType}|${entry.matchNo}|${entry.orderName || ""}`;
  }

  function entryMap() {
    return new Map(entries.map((entry) => [makeKey(entry), entry]));
  }

  function createLink(entry, orderLink = false) {
    if (entry.status !== "available" || !entry.archiveUrl) {
      const unavailable = document.createElement("span");
      unavailable.className = "inhigh-match-link inhigh-match-link--unavailable";
      unavailable.textContent = "動画未確認";
      unavailable.title = entry.statusReason || "開始位置を確定できないため、リンクを作成していません。";
      return unavailable;
    }

    const link = document.createElement("a");
    link.className = `inhigh-match-link${orderLink ? " inhigh-match-link--added-to-order" : ""}`;
    link.href = entry.archiveUrl;
    link.textContent = "動画を見る";
    link.title = `インハイTV ${entry.date} 第${entry.court}コート ${entry.startSeconds}秒`;
    link.addEventListener("click", (event) => event.stopPropagation());
    return link;
  }

  function appendOnce(container, entry, orderLink = false) {
    if (!container || container.dataset.inhighMatchLinkAdded === "true") {
      return;
    }
    container.dataset.inhighMatchLinkAdded = "true";
    const link = createLink(entry, orderLink);
    container.append(link);
  }

  function scanIndividual(map) {
    document.querySelectorAll("bsw-individual-match-card").forEach((card) => {
      if (seen.has(card)) {
        return;
      }
      const matchNo = findMatchNo(card.textContent);
      const entry = map.get(`individual|${matchNo}|`);
      if (!entry) {
        return;
      }
      seen.add(card);
      appendOnce(card.querySelector(".item") || card, entry);
    });
  }

  function scanTeam(map) {
    document.querySelectorAll("bsw-team-order-card").forEach((card) => {
      if (seen.has(card)) {
        return;
      }
      const parent = card.closest("bsw-team-match-card") || card.parentElement;
      const matchNo = findMatchNo(parent?.textContent || "");
      const orderName = findOrderName(card.textContent);
      const entry = map.get(`team|${matchNo}|${orderName}`);
      if (!entry) {
        return;
      }
      seen.add(card);
      appendOnce(card.querySelector(".item") || card, entry, true);
    });
  }

  function scan() {
    scanScheduled = false;
    if (!loaded) {
      return;
    }
    const map = entryMap();
    if (pageKind() === "individual") {
      scanIndividual(map);
    } else {
      scanTeam(map);
    }
  }

  function scheduleScan() {
    if (scanScheduled) {
      return;
    }
    scanScheduled = true;
    window.requestAnimationFrame(scan);
  }

  async function loadData() {
    try {
      const response = await fetch(chrome.runtime.getURL(DATA_PATH));
      if (!response.ok) {
        throw new Error(`data request failed: ${response.status}`);
      }
      const data = await response.json();
      entries = (data.matches || []).filter((entry) => entry.tournamentType === pageKind());
      loaded = true;
      scheduleScan();
    } catch (error) {
      console.warn("[inhigh-match-links] データを読み込めませんでした", error);
    }
  }

  const observer = new MutationObserver(scheduleScan);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  loadData();
})();
