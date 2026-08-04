const DATA_URL = "data/matches.json";

const state = {
  data: null,
  matches: [],
};

const elements = {
  list: document.querySelector("#matches"),
  summary: document.querySelector("#result-summary"),
  type: document.querySelector("#type-filter"),
  category: document.querySelector("#category-filter"),
  date: document.querySelector("#date-filter"),
  court: document.querySelector("#court-filter"),
  search: document.querySelector("#search-filter"),
  availableOnly: document.querySelector("#available-only"),
  total: document.querySelector("#count-total"),
  available: document.querySelector("#count-available"),
  notPlayed: document.querySelector("#count-not-played"),
  unavailable: document.querySelector("#count-unavailable"),
  generatedAt: document.querySelector("#generated-at"),
};

function option(label, value) {
  const element = document.createElement("option");
  element.value = value;
  element.textContent = label;
  return element;
}

function uniqueSorted(values) {
  return [...new Set(values.filter(Boolean))].sort((a, b) => String(a).localeCompare(String(b), "ja", { numeric: true }));
}

function setOptions(select, values, formatter = (value) => value) {
  for (const value of uniqueSorted(values)) {
    select.append(option(formatter(value), value));
  }
}

function dateLabel(value) {
  if (!value) return "日付未確認";
  const [, month, day] = String(value).split("-");
  return `${month}/${day}`;
}

function statusLabel(entry) {
  if (entry.status === "not_played") return "未実施";
  if (entry.status === "unavailable") return "動画未確認";
  return "動画リンクあり";
}

function typeLabel(entry) {
  return entry.tournamentType === "team" ? "団体" : "個人";
}

function searchableText(entry) {
  return [
    entry.tournamentName,
    entry.category,
    entry.eventTitle,
    entry.round,
    entry.matchNo,
    entry.orderName,
    entry.date,
    entry.court,
    ...((entry.sides || []).flatMap((side) => [side.name, ...(side.players || []).flatMap((player) => [player.name, player.belong])])),
  ].join(" ").toLocaleLowerCase("ja");
}

function filteredMatches() {
  const query = elements.search.value.trim().toLocaleLowerCase("ja");
  return state.matches.filter((entry) => {
    if (elements.type.value !== "all" && entry.tournamentType !== elements.type.value) return false;
    if (elements.category.value !== "all" && entry.category !== elements.category.value) return false;
    if (elements.date.value !== "all" && entry.date !== elements.date.value) return false;
    if (elements.court.value !== "all" && entry.court !== elements.court.value) return false;
    if (elements.availableOnly.checked && entry.status !== "available") return false;
    if (query && !searchableText(entry).includes(query)) return false;
    return true;
  });
}

function appendText(parent, tagName, className, text) {
  const element = document.createElement(tagName);
  element.className = className;
  element.textContent = text;
  parent.append(element);
  return element;
}

function renderSides(parent, entry) {
  const sides = entry.sides || [];
  if (!sides.length) {
    appendText(parent, "p", "side-line side-line--empty", "対戦者名はBIRD SCOREで確認");
    return;
  }
  sides.forEach((side, index) => {
    const line = document.createElement("p");
    line.className = "side-line";
    line.textContent = side.name || `${index + 1}チーム`;
    if (side.players?.length) {
      const players = side.players.map((player) => player.name).filter(Boolean).join("・");
      if (players && players !== side.name) {
        const detail = document.createElement("span");
        detail.textContent = `（${players}）`;
        line.append(" ", detail);
      }
    }
    parent.append(line);
  });
}

function renderCard(entry) {
  const card = document.createElement("article");
  card.className = "match-card";

  const meta = document.createElement("div");
  meta.className = "match-card__meta";
  appendText(meta, "span", "match-card__eyebrow", `${typeLabel(entry)} · ${entry.category || "種目未確認"}`);
  appendText(meta, "strong", "match-card__number", `${entry.matchNo || "試合番号未確認"}${entry.orderName ? ` · ${entry.orderName}` : ""}`);
  appendText(meta, "span", "match-card__detail", `${dateLabel(entry.date)} · ${entry.court ? `${entry.court}コート` : "コート未確認"} · ${entry.round || "ラウンド未確認"}`);

  const sides = document.createElement("div");
  sides.className = "match-card__sides";
  appendText(sides, "span", "match-card__detail", entry.eventTitle || entry.tournamentName || "");
  renderSides(sides, entry);

  const action = document.createElement("div");
  action.className = "match-card__action";
  if (entry.birdScoreUrl) {
    const scoreLink = document.createElement("a");
    scoreLink.className = "score-button";
    scoreLink.href = entry.birdScoreUrl;
    scoreLink.target = "_blank";
    scoreLink.rel = "noreferrer";
    scoreLink.textContent = "BIRD SCORE";
    scoreLink.title = "公式BIRD SCOREを開く";
    action.append(scoreLink);
  }
  if (entry.status === "available" && entry.archiveUrl) {
    const link = document.createElement("a");
    link.className = "video-button";
    link.href = entry.archiveUrl;
    link.target = "_blank";
    link.rel = "noreferrer";
    link.textContent = "動画を見る";
    link.title = `${entry.archiveTitle || "インハイTV公式アーカイブ"} ${entry.startSeconds}秒から`;
    action.append(link);
  } else {
    const unavailable = document.createElement("span");
    unavailable.className = "unavailable-button";
    unavailable.title = entry.statusReason || "開始位置を確認できないため、リンクを有効化していません。";
    unavailable.textContent = statusLabel(entry);
    action.append(unavailable);
  }

  card.append(meta, sides, action);
  return card;
}

function render() {
  const matches = filteredMatches();
  elements.list.replaceChildren();
  if (!matches.length) {
    appendText(elements.list, "p", "empty-state", "条件に一致する試合がありません。");
  } else {
    const fragment = document.createDocumentFragment();
    matches.forEach((entry) => fragment.append(renderCard(entry)));
    elements.list.append(fragment);
  }
  elements.summary.textContent = `${matches.length.toLocaleString("ja-JP")}件表示 / 全${state.matches.length.toLocaleString("ja-JP")}件`;
}

function initialiseFilters() {
  setOptions(elements.category, state.matches.map((entry) => entry.category), (value) => value || "種目未確認");
  setOptions(elements.date, state.matches.map((entry) => entry.date), dateLabel);
  setOptions(elements.court, state.matches.map((entry) => entry.court), (value) => `${value}コート`);
  [elements.type, elements.category, elements.date, elements.court, elements.search, elements.availableOnly].forEach((element) => {
    element.addEventListener("input", render);
    element.addEventListener("change", render);
  });
}

async function load() {
  try {
    const response = await fetch(DATA_URL, { cache: "no-store" });
    if (!response.ok) throw new Error(`データ取得に失敗しました（${response.status}）`);
    state.data = await response.json();
    state.matches = Array.isArray(state.data.matches) ? state.data.matches : [];
    const counts = state.data.counts || {};
    elements.total.textContent = Number(counts.total || state.matches.length).toLocaleString("ja-JP");
    elements.available.textContent = Number(counts.available || 0).toLocaleString("ja-JP");
    elements.notPlayed.textContent = Number(counts.notPlayed || 0).toLocaleString("ja-JP");
    elements.unavailable.textContent = Number(counts.unavailable || 0).toLocaleString("ja-JP");
    if (state.data.generatedAt) {
      elements.generatedAt.textContent = `データ生成日時: ${new Date(state.data.generatedAt).toLocaleString("ja-JP")}`;
    }
    initialiseFilters();
    render();
  } catch (error) {
    elements.list.replaceChildren();
    appendText(elements.list, "p", "error-state", `データを読み込めませんでした。${error.message}`);
    elements.summary.textContent = "読み込みエラー";
  }
}

load();
