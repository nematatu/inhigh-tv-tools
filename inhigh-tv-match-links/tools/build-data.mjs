import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const YEAR = 2026;
const BIRD_ORIGIN = "https://www.birdscore.live";
const INHIGH_ORIGIN = "https://inhightv.sportsbull.jp";
const INHIGH_API_ORIGIN = `${INHIGH_ORIGIN}/api/v1`;
const PLAYBACK_ORIGIN = "https://playback.api.streaks.jp";
const DATE_MIN = `${YEAR}-07-23`;
const DATE_MAX = `${YEAR}-07-27`;

const TOURNAMENTS = [
  {
    tournamentType: "team",
    tournamentId: "T40qbkSnBKFDqAn75xVu",
    slug: "interhigh-2026-wakayama-team",
    pageUrl: `${BIRD_ORIGIN}/web/interhigh-2026-wakayama-team/`,
  },
  {
    tournamentType: "individual",
    tournamentId: "NyeImuLPwBbHxTK6EK8m",
    slug: "interhigh-2026-wakayama-Individual",
    pageUrl: `${BIRD_ORIGIN}/web/interhigh-2026-wakayama-Individual/`,
  },
];

const sleep = (ms) => new Promise((resolvePromise) => setTimeout(resolvePromise, ms));

async function fetchJson(url, options = {}) {
  const {
    headers = {},
    retries = 3,
    optional = false,
    label = url,
  } = options;

  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      const response = await fetch(url, {
        headers: {
          Accept: "application/json, text/plain, */*",
          "User-Agent": "inhigh-tv-match-links-data-builder/0.1",
          ...headers,
        },
        signal: AbortSignal.timeout(30000),
      });
      if (!response.ok) {
        throw new Error(`${response.status} ${response.statusText}`);
      }
      return await response.json();
    } catch (error) {
      if (attempt < retries) {
        await sleep(300 * 2 ** attempt);
        continue;
      }
      if (optional) {
        console.warn(`optional data unavailable: ${label}`);
        return null;
      }
      throw new Error(`${label}: ${error.message}`);
    }
  }
  return null;
}

async function mapLimit(items, limit, worker) {
  const output = new Array(items.length);
  let next = 0;
  const workers = Array.from(
    { length: Math.min(limit, Math.max(1, items.length)) },
    async () => {
      while (true) {
        const index = next;
        next += 1;
        if (index >= items.length) {
          return;
        }
        output[index] = await worker(items[index], index);
      }
    },
  );
  await Promise.all(workers);
  return output;
}

function asArray(value, key) {
  if (Array.isArray(value)) {
    return value;
  }
  if (value && Array.isArray(value[key])) {
    return value[key];
  }
  return [];
}

function dateInRange(date) {
  return typeof date === "string" && date >= DATE_MIN && date <= DATE_MAX;
}

function parseCourtNumber(title) {
  return String(title || "").match(/(\d+)\s*コート/)?.[1] || "";
}

function parseGroupDate(groupName, fallbackTimestamp) {
  const match = String(groupName || "").match(/(\d{1,2})\s*\/\s*(\d{1,2})/);
  if (match) {
    return `${YEAR}-${String(Number(match[1])).padStart(2, "0")}-${String(Number(match[2])).padStart(2, "0")}`;
  }
  if (Number.isFinite(fallbackTimestamp)) {
    const date = new Date(fallbackTimestamp);
    const formatter = new Intl.DateTimeFormat("en-CA", {
      timeZone: "Asia/Tokyo",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    });
    return formatter.format(date);
  }
  return "";
}

function flattenEvents(tournament) {
  const result = new Map();
  for (const category of asArray(tournament?.tournamentEvents)) {
    for (const event of asArray(category.events)) {
      result.set(event.eventId, {
        category: category.category || "",
        title: category.title || event.class || "",
        eventClass: event.class || "",
      });
    }
  }
  return result;
}

function flattenRounds(tournament) {
  return new Map(asArray(tournament?.rounds).map((round) => [round.roundId, round.roundName || ""]));
}

function flattenMatchConfigs(tournament) {
  return new Map(
    asArray(tournament?.matchConfigs).map((config) => [config.matchConfigId, config.matchName || ""]),
  );
}

function flattenCourts(courts) {
  return new Map(
    asArray(courts, "courts").map((court) => [court.courtId, String(court.courtName || "")]),
  );
}

function flattenOrganizations(orgs) {
  const result = new Map();
  for (const org of asArray(orgs, "orgs")) {
    result.set(org.orgId, {
      name: org.orgName || org.orgShortName || "",
      shortName: org.orgShortName || org.orgName || "",
      players: new Map(asArray(org.players).map((player) => [player.playerId, player.playerName || ""])),
    });
  }
  return result;
}

function flattenIndividualTeams(teams) {
  const result = new Map();
  for (const team of asArray(teams, "teams")) {
    result.set(team.teamId, {
      players: asArray(team.players).map((player) => ({
        name: player.playerName || "",
        belong: String(player.belong || "").trim(),
      })),
    });
  }
  return result;
}

function teamSide(team, teamIndex, match, organizations, individualTeams, tournamentType) {
  if (tournamentType === "individual") {
    const found = individualTeams.get(team?.teamId);
    return {
      name: found?.players?.map((player) => player.name).filter(Boolean).join("・") || "",
      players: found?.players || [],
    };
  }

  const organization = organizations.get(match?.orgs?.[teamIndex]?.orgId);
  const players = asArray(team?.players)
    .map((player) => ({ name: organization?.players?.get(player.playerId) || "", belong: "" }))
    .filter((player) => player.name);
  return {
    name: organization?.name || "",
    players,
  };
}

function archiveKey(date, court) {
  return `${date}|${String(court || "")}`;
}

function absoluteUrl(base, value) {
  try {
    return new URL(value, base).href;
  } catch (_error) {
    return "";
  }
}

function firstHlsSource(playback) {
  return asArray(playback?.sources)
    .find((source) => source?.type === "application/x-mpegURL" || /\.m3u8(?:\?|$)/i.test(source?.src || ""))?.src || "";
}

function firstProgramDateTime(text) {
  const match = String(text || "").match(/#EXT-X-PROGRAM-DATE-TIME:([^\r\n]+)/);
  if (!match) {
    return "";
  }
  const timestamp = Date.parse(match[1].trim());
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : "";
}

function firstVariantUrl(masterUrl, text) {
  const lines = String(text || "").split(/\r?\n/).map((line) => line.trim());
  for (let index = 0; index < lines.length; index += 1) {
    if (lines[index].startsWith("#EXT-X-STREAM-INF") && lines[index + 1] && !lines[index + 1].startsWith("#")) {
      return absoluteUrl(masterUrl, lines[index + 1]);
    }
  }
  return masterUrl;
}

async function fetchProgramDateTime(archive, projectId, apiKey) {
  const invalid = (reason) => ({
    ...archive,
    status: "unavailable",
    statusReason: reason,
    programDateTime: null,
    durationSeconds: null,
    archiveUrl: `${INHIGH_ORIGIN}/summer/archive/${archive.archiveId}`,
  });

  if (!archive.mediaId || !/^[a-f0-9]{32}$/i.test(String(archive.mediaId))) {
    return invalid("インハイTVのメディアIDを確認できませんでした。");
  }

  try {
    const playback = await fetchJson(
      `${PLAYBACK_ORIGIN}/v1/projects/${encodeURIComponent(projectId)}/medias/${encodeURIComponent(archive.mediaId)}`,
      { headers: { "X-Streaks-Api-Key": apiKey }, label: `playback ${archive.archiveId}` },
    );
    const source = firstHlsSource(playback);
    if (!source) {
      return invalid("HLS配信元が見つかりませんでした。");
    }
    const masterResponse = await fetch(source, {
      headers: { Accept: "application/vnd.apple.mpegurl, application/x-mpegURL, */*" },
      signal: AbortSignal.timeout(30000),
    });
    if (!masterResponse.ok) {
      throw new Error(`HLS master ${masterResponse.status}`);
    }
    const masterText = await masterResponse.text();
    const variantUrl = firstVariantUrl(source, masterText);
    const variantResponse = variantUrl === source ? masterResponse : await fetch(variantUrl, {
      headers: { Accept: "application/vnd.apple.mpegurl, application/x-mpegURL, */*" },
      signal: AbortSignal.timeout(30000),
    });
    if (!variantResponse.ok) {
      throw new Error(`HLS variant ${variantResponse.status}`);
    }
    const variantText = variantUrl === source ? masterText : await variantResponse.text();
    const programDateTime = firstProgramDateTime(variantText);
    if (!programDateTime) {
      return invalid("HLSの開始日時を確認できませんでした。");
    }
    if (programDateTime.slice(0, 10) !== archive.date) {
      return invalid("公式アーカイブの公開日とHLS開始日が一致しませんでした。");
    }
    const duration = Number(playback.duration);
    return {
      ...archive,
      status: "available",
      statusReason: "",
      programDateTime,
      durationSeconds: Number.isFinite(duration) && duration > 0 ? Math.floor(duration) : null,
      archiveUrl: `${INHIGH_ORIGIN}/summer/archive/${archive.archiveId}`,
    };
  } catch (error) {
    return invalid(`動画情報の取得に失敗しました（${error.message}）。`);
  }
}

async function fetchInhighArchives() {
  const firstPage = await fetchJson(`${INHIGH_API_ORIGIN}/archives/all?page=1`, { label: "archives page 1" });
  const lastPage = Math.max(1, Number(firstPage?.meta?.last_page) || 28);
  const remainingPages = await mapLimit(Array.from({ length: lastPage - 1 }, (_, index) => index + 2), 6, (page) =>
    fetchJson(`${INHIGH_API_ORIGIN}/archives/all?page=${page}`, { label: `archives page ${page}` }),
  );
  const pages = [firstPage, ...remainingPages];
  const archives = pages
    .flatMap((page) => asArray(page?.response?.archives ?? page?.response ?? page?.archives ?? page))
    .filter((archive) => Number(archive?.competition_id) === 9 && dateInRange(archive?.date))
    .map((archive) => ({
      archiveId: Number(archive.archive_id ?? archive.id),
      date: archive.date,
      court: parseCourtNumber(archive.title),
      title: archive.title || "",
      mediaId: String(archive.media_id || archive.vods?.[0]?.streaks_media_id || ""),
      competitionName: archive.competition_name || "バドミントン",
    }))
    .filter((archive) => archive.archiveId && archive.date && archive.court);

  const settings = await fetchJson(`${INHIGH_API_ORIGIN}/video_setting`, { label: "video setting" });
  const response = settings?.response || {};
  const projectId = response.brightcove_account_id;
  const apiKey = response.brightcove_vod_player_id;
  if (!projectId || !apiKey) {
    throw new Error("インハイTVの動画設定に必要な公開プレーヤー情報がありません。");
  }

  const hydrated = await mapLimit(archives, 8, (archive) => fetchProgramDateTime(archive, projectId, apiKey));
  const byKey = new Map(hydrated.map((archive) => [archiveKey(archive.date, archive.court), archive]));
  return { archives: hydrated, byKey };
}

function scheduleRows(schedule) {
  const rows = [];
  for (const [groupId, matches] of Object.entries(schedule?.matches || {})) {
    for (const match of asArray(matches)) {
      rows.push({
        groupId,
        matchId: match.matchId,
        eventId: match.eventId,
        orders: asArray(match.orders),
      });
    }
  }
  return rows;
}

async function fetchBirdTournament(config) {
  const base = `${BIRD_ORIGIN}/json/${config.tournamentId}`;
  const [tournament, schedule, courts, teams, orgs] = await Promise.all([
    fetchJson(`${base}/tournament.json`, { label: `${config.tournamentType} tournament` }),
    fetchJson(`${base}/schedule.json`, { label: `${config.tournamentType} schedule` }),
    fetchJson(`${base}/courts.json`, { label: `${config.tournamentType} courts` }),
    config.tournamentType === "individual"
      ? fetchJson(`${base}/teams.json`, { optional: true, label: `${config.tournamentType} teams` })
      : Promise.resolve(null),
    config.tournamentType === "team"
      ? fetchJson(`${base}/orgs.json`, { optional: true, label: `${config.tournamentType} organizations` })
      : Promise.resolve(null),
  ]);
  const scheduleEntries = scheduleRows(schedule);
  const uniqueMatchIds = [...new Set(scheduleEntries.map((row) => row.matchId).filter(Boolean))];
  const matchDataList = await mapLimit(uniqueMatchIds, 12, (matchId) =>
    fetchJson(`${base}/matches/${encodeURIComponent(matchId)}/match.json`, {
      optional: true,
      label: `${config.tournamentType} match ${matchId}`,
    }),
  );
  const matches = new Map(matchDataList.filter(Boolean).map((match) => [match.matchId, match]));
  const orderRefs = [];
  for (const row of scheduleEntries) {
    const match = matches.get(row.matchId);
    const refs = row.orders.length ? row.orders : asArray(match?.orders);
    for (const order of refs) {
      if (order?.orderId) {
        orderRefs.push({ groupId: row.groupId, eventId: row.eventId, matchId: row.matchId, orderId: order.orderId });
      }
    }
  }
  const uniqueOrderRefs = [...new Map(orderRefs.map((ref) => [`${ref.matchId}|${ref.orderId}`, ref])).values()];
  const orderDataList = await mapLimit(uniqueOrderRefs, 12, (ref) =>
    fetchJson(`${base}/matches/${encodeURIComponent(ref.matchId)}/${encodeURIComponent(ref.orderId)}/order.json`, {
      optional: true,
      label: `${config.tournamentType} order ${ref.orderId}`,
    }),
  );
  const orderDataByKey = new Map(
    orderDataList.filter(Boolean).map((order) => [`${order.matchId}|${order.orderId}`, order]),
  );
  return {
    ...config,
    base,
    tournament,
    schedule,
    courts: flattenCourts(courts),
    teams: flattenIndividualTeams(teams),
    organizations: flattenOrganizations(orgs),
    events: flattenEvents(tournament),
    rounds: flattenRounds(tournament),
    matchConfigs: flattenMatchConfigs(tournament),
    scheduleEntries,
    matches,
    orderRefs: uniqueOrderRefs,
    orderDataByKey,
  };
}

function buildEntry(bird, ref, order, archiveByKey) {
  const match = bird.matches.get(ref.matchId);
  const event = bird.events.get(ref.eventId || match?.eventId) || {};
  const orderRef = asArray(match?.orders).find((item) => item.orderId === ref.orderId);
  const matchConfigId = order?.matchConfigId || orderRef?.matchConfigId || "";
  const orderName = bird.matchConfigs.get(matchConfigId) || (bird.tournamentType === "individual" ? "" : "試合");
  const groupName = asArray(bird.tournament?.matchGroups).find((group) => group.matchGroupId === ref.groupId)?.matchGroupName || "";
  const date = parseGroupDate(groupName, Number(order?.startTime));
  const court = bird.courts.get(order?.courtId) || "";
  const archive = archiveByKey.get(archiveKey(date, court));
  const startTime = Number(order?.startTime);
  const hasStartTime = Number.isFinite(startTime) && startTime > 0;
  const hasCourt = Boolean(court);
  let status = "available";
  let statusReason = "";
  let startSeconds = null;
  let archiveUrl = null;

  if (!hasStartTime) {
    status = "not_played";
    statusReason = "BIRD SCOREに実際の開始時刻がありません。";
  } else if (!hasCourt) {
    status = "unavailable";
    statusReason = "コート情報を確認できませんでした。";
  } else if (!archive || archive.status !== "available" || !archive.programDateTime) {
    status = "unavailable";
    statusReason = archive?.statusReason || "同日・同コートの公式アーカイブを確認できませんでした。";
  } else {
    const offset = (startTime - Date.parse(archive.programDateTime)) / 1000;
    const duration = Number(archive.durationSeconds);
    if (!Number.isFinite(offset) || offset < 0 || (Number.isFinite(duration) && duration > 0 && offset > duration)) {
      status = "unavailable";
      statusReason = "試合開始時刻と公式アーカイブの範囲が一致しませんでした。";
    } else {
      startSeconds = Math.floor(offset);
      archiveUrl = `${archive.archiveUrl}?start=${startSeconds}`;
    }
  }

  const teams = asArray(order?.teams);
  const sides = teams.map((team, index) => teamSide(
    team,
    index,
    match,
    bird.organizations,
    bird.teams,
    bird.tournamentType,
  ));

  return {
    id: `${bird.tournamentType}:${ref.matchId}:${ref.orderId}`,
    tournamentType: bird.tournamentType,
    tournamentName: bird.tournament?.tournamentName || "2026年インターハイ・バドミントン",
    tournamentPageUrl: bird.pageUrl,
    category: event.category || "",
    eventTitle: event.title || event.eventClass || "",
    round: bird.rounds.get(match?.roundId) || "",
    matchNo: match?.matchNo || "",
    orderName,
    date,
    court,
    matchId: ref.matchId,
    orderId: ref.orderId,
    birdScoreUrl: bird.pageUrl,
    status,
    statusReason,
    startTime: hasStartTime ? new Date(startTime).toISOString() : null,
    startSeconds,
    archiveId: archive?.archiveId || null,
    archiveUrl,
    archiveTitle: archive?.title || "",
    sides,
  };
}

function sortEntries(a, b) {
  return [a.date, Number(a.court) || 999, a.startTime || "9999", a.matchNo, a.orderName]
    .map(String)
    .join("|")
    .localeCompare([b.date, Number(b.court) || 999, b.startTime || "9999", b.matchNo, b.orderName].map(String).join("|"), "ja", { numeric: true });
}

async function main() {
  console.log("インハイTV公式アーカイブ情報を取得しています…");
  const inhigh = await fetchInhighArchives();
  console.log(`公式アーカイブ ${inhigh.archives.length}件を確認しました。`);
  const birds = await mapLimit(TOURNAMENTS, 2, (config) => fetchBirdTournament(config));
  const matches = birds.flatMap((bird) => bird.orderRefs.map((ref) => buildEntry(
    bird,
    ref,
    bird.orderDataByKey.get(`${ref.matchId}|${ref.orderId}`),
    inhigh.byKey,
  ))).sort(sortEntries);

  const counts = {
    total: matches.length,
    available: matches.filter((entry) => entry.status === "available").length,
    notPlayed: matches.filter((entry) => entry.status === "not_played").length,
    unavailable: matches.filter((entry) => entry.status === "unavailable").length,
    team: matches.filter((entry) => entry.tournamentType === "team").length,
    individual: matches.filter((entry) => entry.tournamentType === "individual").length,
  };
  const data = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    source: {
      year: YEAR,
      birdScore: BIRD_ORIGIN,
      inhighTv: INHIGH_ORIGIN,
      verifiedDateRange: { from: DATE_MIN, to: DATE_MAX },
    },
    counts,
    archives: inhigh.archives.map((archive) => ({
      archiveId: archive.archiveId,
      date: archive.date,
      court: archive.court,
      title: archive.title,
      competitionName: archive.competitionName,
      mediaId: archive.mediaId,
      status: archive.status,
      statusReason: archive.statusReason,
      programDateTime: archive.programDateTime,
      durationSeconds: archive.durationSeconds,
      archiveUrl: archive.archiveUrl,
    })),
    matches,
  };

  const outputPaths = [
    resolve(ROOT, "data/matches.json"),
    resolve(ROOT, "site/data/matches.json"),
    resolve(ROOT, "extension/data/matches.json"),
  ];
  const serialized = `${JSON.stringify(data, null, 2)}\n`;
  for (const outputPath of outputPaths) {
    await mkdir(dirname(outputPath), { recursive: true });
    await writeFile(outputPath, serialized, "utf8");
  }
  console.log(`試合リンク ${matches.length}件を生成しました。`);
  console.log(`有効 ${counts.available} / 未実施 ${counts.notPlayed} / 未確認 ${counts.unavailable}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || error);
  process.exitCode = 1;
});
