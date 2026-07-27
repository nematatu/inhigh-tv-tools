#!/usr/bin/env python3
"""2026年インターハイ・バドミントン（7月23〜25日）の長尺アーカイブ保存用。

重要:
  - スクリプト本体以外は、外付け物理ディスクと検証できたボリュームにのみ書き込みます。
  - 内蔵ストレージへのフォールバックは行いません。
  - 完了済みMP4はffprobeで検証してスキップするため、何度でも再実行できます。

Finderからダブルクリックするか、Terminalで次のように実行してください。

  ./download_inhigh_2026.command
  ./download_inhigh_2026.command --volume "HDDの名前"
  ./download_inhigh_2026.command --volume "HDDの名前" --date 2026-07-23

既定は最高画質（最大1080p）、同時ダウンロード2本です。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import datetime as dt
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


SITE_ORIGIN = "https://inhightv.sportsbull.jp"
ARCHIVES_API = f"{SITE_ORIGIN}/api/v1/archives/all"
VIDEO_SETTING_API = f"{SITE_ORIGIN}/api/v1/video_setting"
PLAYBACK_API = "https://playback.api.streaks.jp/v1/projects/{project}/medias/{media_id}"
TARGET_COMPETITION_ID = 9
TARGET_DATES = ("2026-07-23", "2026-07-24", "2026-07-25")
EXPECTED_ARCHIVE_COUNTS = {
    "2026-07-23": 36,
    "2026-07-24": 16,
    "2026-07-25": 36,
}
OUTPUT_DIRECTORY_NAME = "インターハイ2026_バドミントン_7月23-25日"
STATE_DIRECTORY_NAME = ".inhigh-download"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 Chrome/150 Safari/537.36"
VOLUMES_ROOT = Path("/Volumes")
MINIMUM_EXTRA_BYTES = 10 * 1024**3
ESTIMATE_MARGIN = 1.08


class DownloadError(RuntimeError):
    """安全に処理を続行できない場合の例外。"""


@dataclasses.dataclass(frozen=True)
class ArchiveItem:
    archive_id: int
    date: str
    court: int
    title: str
    media_id: str | None
    ref_id: str | None
    youtube_video_id: str | None

    @property
    def filename(self) -> str:
        return f"{self.date}_{self.court:02d}.mp4"

    @property
    def page_url(self) -> str:
        return f"{SITE_ORIGIN}/summer/archive/{self.archive_id}"


@dataclasses.dataclass(frozen=True)
class StreamInfo:
    item: ArchiveItem
    variant_url: str
    duration_seconds: float
    width: int
    height: int
    average_bitrate: int

    @property
    def estimated_bytes(self) -> int:
        return int(self.duration_seconds * self.average_bitrate / 8)


@dataclasses.dataclass(frozen=True)
class Volume:
    mount_point: Path
    device_identifier: str
    volume_uuid: str
    name: str
    filesystem: str


ACTIVE_PROCESSES: set[subprocess.Popen[bytes]] = set()
ACTIVE_PROCESSES_LOCK = threading.Lock()
STOP_EVENT = threading.Event()
LOG_LOCK = threading.Lock()


def human_bytes(value: int | float) -> str:
    units = ("B", "KB", "MB", "GB", "TB", "PB")
    number = float(value)
    for unit in units:
        if abs(number) < 1000 or unit == units[-1]:
            return f"{number:.2f}{unit}"
        number /= 1000
    return f"{number:.2f}PB"


def human_hours(seconds: int | float) -> str:
    return f"{float(seconds) / 3600:.1f}時間"


def fetch_bytes(url: str, *, headers: dict[str, str] | None = None, timeout: int = 30) -> bytes:
    request_headers = {"User-Agent": USER_AGENT, "Accept": "*/*"}
    if headers:
        request_headers.update(headers)
    last_error: Exception | None = None

    for attempt in range(4):
        if STOP_EVENT.is_set():
            raise DownloadError("中断されました。")
        request = urllib.request.Request(url, headers=request_headers)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            last_error = error
            if error.code not in (408, 429, 500, 502, 503, 504):
                break
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = error
        if attempt < 3:
            time.sleep(min(2**attempt, 8))

    raise DownloadError(f"通信に失敗しました: {url} ({last_error})")


def fetch_json(url: str, *, headers: dict[str, str] | None = None) -> dict[str, Any]:
    raw = fetch_bytes(url, headers=headers)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DownloadError(f"JSONを解析できませんでした: {url} ({error})") from error
    if not isinstance(value, dict):
        raise DownloadError(f"API応答の形式が不正です: {url}")
    return value


def api_response(payload: dict[str, Any], url: str) -> Any:
    status = payload.get("status")
    if isinstance(status, dict) and int(status.get("code", 200)) != 200:
        raise DownloadError(f"APIエラー: {url} ({status})")
    if "response" not in payload:
        raise DownloadError(f"API応答にresponseがありません: {url}")
    return payload["response"]


def extract_court(title: str) -> int:
    match = re.search(r"(?<!\d)(\d{1,3})\s*コート", title)
    if not match:
        raise DownloadError(f"コート番号を読み取れません: {title}")
    court = int(match.group(1))
    if court <= 0:
        raise DownloadError(f"コート番号が不正です: {title}")
    return court


def load_archive_inventory(target_dates: tuple[str, ...] = TARGET_DATES) -> list[ArchiveItem]:
    target_date_set = set(target_dates)
    first_url = f"{ARCHIVES_API}?page=1"
    first_payload = fetch_json(first_url)
    pages = [first_payload]
    meta = first_payload.get("meta") or {}
    last_page = max(1, int(meta.get("last_page", 1)))

    for page in range(2, last_page + 1):
        pages.append(fetch_json(f"{ARCHIVES_API}?page={page}"))

    archives_by_id: dict[int, dict[str, Any]] = {}
    for page_number, payload in enumerate(pages, start=1):
        records = api_response(payload, f"{ARCHIVES_API}?page={page_number}")
        if not isinstance(records, list):
            raise DownloadError("アーカイブ一覧の形式が不正です。")
        for record in records:
            if not isinstance(record, dict):
                continue
            if int(record.get("competition_id", -1)) != TARGET_COMPETITION_ID:
                continue
            if str(record.get("date")) not in target_date_set:
                continue
            archive_id = int(record.get("id"))
            archives_by_id[archive_id] = record

    items: list[ArchiveItem] = []
    for archive_id, record in archives_by_id.items():
        title = str(record.get("title") or record.get("division") or "")
        vods = record.get("vods") or []
        if len(vods) > 1:
            raise DownloadError(
                f"1コートに複数動画があり、指定ファイル名では区別できません: archive_id={archive_id}"
            )
        vod = vods[0] if vods and isinstance(vods[0], dict) else {}
        items.append(
            ArchiveItem(
                archive_id=archive_id,
                date=str(record["date"]),
                court=extract_court(title),
                title=title,
                media_id=str(vod["streaks_media_id"]) if vod.get("streaks_media_id") else None,
                ref_id=str(vod["streaks_ref_id"]) if vod.get("streaks_ref_id") else None,
                youtube_video_id=(
                    str(vod["youtube_video_id"]) if vod.get("youtube_video_id") else None
                ),
            )
        )

    items.sort(key=lambda item: (item.date, item.court, item.archive_id))
    filenames = [item.filename for item in items]
    if len(filenames) != len(set(filenames)):
        raise DownloadError("同じ日付・コート番号の動画が複数あり、ファイル名が重複します。")
    if not items:
        raise DownloadError("対象期間のバドミントン動画が見つかりませんでした。")
    return items


def load_player_credentials() -> tuple[str, str]:
    payload = fetch_json(VIDEO_SETTING_API)
    settings = api_response(payload, VIDEO_SETTING_API)
    if not isinstance(settings, dict):
        raise DownloadError("動画設定APIの形式が不正です。")
    project = str(settings.get("brightcove_account_id") or "")
    api_key = str(settings.get("brightcove_player_id") or "")
    if not project or not api_key:
        raise DownloadError("動画配信設定を取得できませんでした。")
    return project, api_key


def parse_manifest_variants(manifest: str) -> list[dict[str, Any]]:
    lines = [line.strip() for line in manifest.splitlines() if line.strip()]
    variants: list[dict[str, Any]] = []
    for index, line in enumerate(lines):
        if not line.startswith("#EXT-X-STREAM-INF:") or index + 1 >= len(lines):
            continue
        url = lines[index + 1]
        if url.startswith("#"):
            continue
        attributes = line.split(":", 1)[1]
        pairs = {
            key: value.strip('"')
            for key, value in re.findall(r"([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)", attributes)
        }
        resolution = pairs.get("RESOLUTION", "0x0").lower().split("x", 1)
        try:
            width, height = int(resolution[0]), int(resolution[1])
        except (ValueError, IndexError):
            width, height = 0, 0
        average = int(pairs.get("AVERAGE-BANDWIDTH") or pairs.get("BANDWIDTH") or 0)
        peak = int(pairs.get("BANDWIDTH") or average)
        variants.append(
            {
                "url": url,
                "width": width,
                "height": height,
                "average_bitrate": average,
                "peak_bitrate": peak,
            }
        )
    return variants


def choose_variant(variants: list[dict[str, Any]], max_height: int) -> dict[str, Any]:
    video_variants = [variant for variant in variants if int(variant["height"]) > 0]
    if not video_variants:
        raise DownloadError("HLSプレイリストに動画画質がありません。")
    within_limit = [variant for variant in video_variants if int(variant["height"]) <= max_height]
    candidates = within_limit or video_variants
    return max(
        candidates,
        key=lambda variant: (
            int(variant["height"]),
            int(variant["width"]),
            int(variant["average_bitrate"]),
        ),
    )


def resolve_stream(item: ArchiveItem, project: str, api_key: str, max_height: int) -> StreamInfo:
    if not item.media_id or not re.fullmatch(r"[0-9a-fA-F]{32}", item.media_id):
        detail = item.media_id or "未設定"
        raise DownloadError(f"サイト側のメディアIDが不正です: {item.filename} ({detail})")

    playback_url = PLAYBACK_API.format(
        project=urllib.parse.quote(project, safe=""),
        media_id=urllib.parse.quote(item.media_id, safe=""),
    )
    playback = fetch_json(playback_url, headers={"X-Streaks-Api-Key": api_key})
    sources = playback.get("sources") or []
    source = next(
        (
            candidate
            for candidate in sources
            if isinstance(candidate, dict)
            and candidate.get("src")
            and "mpegurl" in str(candidate.get("type", "")).lower()
        ),
        None,
    )
    if not source:
        raise DownloadError(f"HLS動画が見つかりません: {item.filename}")

    master_url = str(source["src"])
    manifest = fetch_bytes(master_url).decode("utf-8", errors="replace")
    variants = parse_manifest_variants(manifest)
    if variants:
        variant = choose_variant(variants, max_height)
        variant_url = urllib.parse.urljoin(master_url, str(variant["url"]))
        width = int(variant["width"])
        height = int(variant["height"])
        average_bitrate = int(variant["average_bitrate"])
    else:
        variant_url = master_url
        resolution = str(source.get("resolution") or "0x0").split("x", 1)
        try:
            width, height = int(resolution[0]), int(resolution[1])
        except (ValueError, IndexError):
            width, height = 0, max_height
        average_bitrate = int(source.get("average_bitrate") or source.get("bandwidth") or 0)

    duration = float(playback.get("duration") or 0)
    if duration <= 0 or average_bitrate <= 0:
        raise DownloadError(f"動画の長さ・ビットレートを取得できません: {item.filename}")
    return StreamInfo(
        item=item,
        variant_url=variant_url,
        duration_seconds=duration,
        width=width,
        height=height,
        average_bitrate=average_bitrate,
    )


def diskutil_info(path: Path) -> dict[str, Any]:
    result = subprocess.run(
        ["/usr/sbin/diskutil", "info", "-plist", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise DownloadError(f"diskutilでボリュームを確認できません: {path}")
    try:
        info = plistlib.loads(result.stdout)
    except Exception as error:
        raise DownloadError(f"ボリューム情報を解析できません: {path} ({error})") from error
    if not isinstance(info, dict):
        raise DownloadError(f"ボリューム情報の形式が不正です: {path}")
    return info


def validate_external_volume(path: Path, expected: Volume | None = None) -> Volume:
    if not path.exists():
        raise DownloadError(f"HDDが見つかりません: {path}")
    info = diskutil_info(path)
    mount_value = info.get("MountPoint")
    if not mount_value:
        raise DownloadError(f"マウントされていません: {path}")
    mount_point = Path(str(mount_value)).resolve()
    requested = path.resolve()
    volumes_root = VOLUMES_ROOT.resolve()
    if requested != mount_point:
        raise DownloadError(f"HDDのマウント直下を指定してください: {mount_point}")
    if os.path.commonpath((str(mount_point), str(volumes_root))) != str(volumes_root):
        raise DownloadError(f"/Volumes配下ではないため拒否しました: {mount_point}")
    if info.get("Internal") is not False:
        raise DownloadError(f"内蔵ストレージと判定されたため拒否しました: {mount_point}")
    external_signal = any(
        (
            info.get("RemovableMediaOrExternalDevice") is True,
            info.get("Ejectable") is True,
            str(info.get("VirtualOrPhysical", "")).lower() == "physical",
        )
    )
    if not external_signal:
        raise DownloadError(f"外付け物理ディスクと確認できないため拒否しました: {mount_point}")
    if info.get("WritableVolume") is not True:
        raise DownloadError(f"HDDが書き込み可能ではありません: {mount_point}")
    if not os.path.ismount(mount_point):
        raise DownloadError(f"マウントポイントではないため拒否しました: {mount_point}")
    filesystem = str(info.get("FilesystemType") or info.get("FilesystemName") or "不明")
    if filesystem.lower() in {"msdos", "fat", "fat32"}:
        raise DownloadError(
            f"FAT32は4GB超の動画を保存できないため拒否しました: {mount_point} ({filesystem})"
        )

    volume = Volume(
        mount_point=mount_point,
        device_identifier=str(info.get("DeviceIdentifier") or ""),
        volume_uuid=str(info.get("VolumeUUID") or ""),
        name=str(info.get("VolumeName") or mount_point.name),
        filesystem=filesystem,
    )
    if not volume.device_identifier:
        raise DownloadError(f"デバイス識別子を確認できません: {mount_point}")
    if expected and (
        volume.device_identifier != expected.device_identifier
        or (expected.volume_uuid and volume.volume_uuid != expected.volume_uuid)
    ):
        raise DownloadError("実行中にHDDが別のデバイスへ変わったため停止しました。")
    return volume


def discover_external_volumes() -> list[Volume]:
    if not VOLUMES_ROOT.exists():
        return []
    found: list[Volume] = []
    for candidate in sorted(VOLUMES_ROOT.iterdir(), key=lambda value: value.name.lower()):
        if candidate.name.startswith(".") or candidate.is_symlink():
            continue
        try:
            found.append(validate_external_volume(candidate))
        except DownloadError:
            continue
    return found


def choose_volume(requested: str | None, assume_yes: bool) -> Volume:
    if requested:
        candidate = Path(requested).expanduser()
        if not candidate.is_absolute():
            candidate = VOLUMES_ROOT / requested
        return validate_external_volume(candidate)

    while True:
        candidates = discover_external_volumes()
        if len(candidates) == 1:
            return candidates[0]
        if len(candidates) > 1:
            if assume_yes or not sys.stdin.isatty():
                names = ", ".join(volume.name for volume in candidates)
                raise DownloadError(f"外付けHDDが複数あります。--volumeで指定してください: {names}")
            print("\n外付けHDDが複数あります:")
            for index, volume in enumerate(candidates, start=1):
                print(f"  {index}. {volume.name} ({volume.mount_point})")
            answer = input("保存先の番号を入力してください: ").strip()
            if answer.isdigit() and 1 <= int(answer) <= len(candidates):
                return candidates[int(answer) - 1]
            print("番号が正しくありません。")
            continue

        if not sys.stdin.isatty():
            raise DownloadError("外付け物理HDDが見つかりません。接続後に再実行してください。")
        input("\n外付けHDDが見つかりません。HDDを接続し、Finderで表示されたらEnterを押してください: ")


def safe_child(volume_root: Path, path: Path) -> Path:
    root = volume_root.resolve()
    resolved = path.resolve(strict=False)
    if os.path.commonpath((str(root), str(resolved))) != str(root):
        raise DownloadError(f"外付けHDDの外を指すパスを拒否しました: {path}")
    if path.is_symlink():
        raise DownloadError(f"シンボリックリンクを拒否しました: {path}")
    return path


def verify_mp4(path: Path, expected_duration: float | None = None) -> tuple[bool, str]:
    if not path.is_file() or path.is_symlink() or path.stat().st_size <= 0:
        return False, "ファイルがないか空です"
    result = subprocess.run(
        [
            shutil.which("ffprobe") or "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration,size:stream=codec_type",
            "-of",
            "json",
            str(path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return False, result.stderr.strip() or "ffprobeエラー"
    try:
        data = json.loads(result.stdout)
        duration = float((data.get("format") or {}).get("duration") or 0)
        streams = data.get("streams") or []
    except (ValueError, json.JSONDecodeError) as error:
        return False, f"ffprobe結果の解析エラー: {error}"
    if not any(stream.get("codec_type") == "video" for stream in streams):
        return False, "映像ストリームがありません"
    minimum = 60.0 if not expected_duration else max(60.0, expected_duration * 0.90)
    if duration < minimum:
        return False, f"動画が短すぎます: {duration:.1f}秒（期待値 {expected_duration or 0:.1f}秒）"
    return True, f"{duration:.1f}秒"


def append_log(log_path: Path, message: str) -> None:
    timestamp = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    line = f"[{timestamp}] {message}\n"
    with LOG_LOCK:
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(line)
            handle.flush()


def terminate_active_processes() -> None:
    STOP_EVENT.set()
    with ACTIVE_PROCESSES_LOCK:
        processes = list(ACTIVE_PROCESSES)
    for process in processes:
        if process.poll() is None:
            try:
                process.send_signal(signal.SIGINT)
            except OSError:
                pass


def run_ffmpeg(
    stream: StreamInfo,
    volume: Volume,
    output_directory: Path,
    state_directory: Path,
    runtime_environment: dict[str, str],
) -> tuple[str, str]:
    item = stream.item
    final_path = safe_child(volume.mount_point, output_directory / item.filename)
    temp_path = safe_child(volume.mount_point, state_directory / "tmp" / f"{item.filename}.part.mp4")
    ffmpeg_log = safe_child(volume.mount_point, state_directory / "logs" / f"{item.filename}.log")

    if final_path.exists():
        valid, detail = verify_mp4(final_path, stream.duration_seconds)
        if valid:
            return "skipped", f"{item.filename}: 完了済み ({detail})"
        return "failed", f"{item.filename}: 同名の不完全なファイルがあります。上書きせず停止 ({detail})"

    validate_external_volume(volume.mount_point, expected=volume)
    command = [
        shutil.which("ffmpeg") or "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "warning",
        "-stats_period",
        "60",
        "-y",
        "-user_agent",
        USER_AGENT,
        "-headers",
        f"Referer: {item.page_url}\r\nOrigin: {SITE_ORIGIN}\r\n",
        "-i",
        stream.variant_url,
        "-map",
        "0:v:0",
        "-map",
        "0:a:0?",
        "-c",
        "copy",
        "-movflags",
        "+faststart",
        str(temp_path),
    ]

    with ffmpeg_log.open("a", encoding="utf-8") as log_handle:
        log_handle.write(
            f"\n=== {dt.datetime.now().astimezone().isoformat()} {stream.width}x{stream.height} ===\n"
        )
        log_handle.flush()
        process = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=log_handle,
            env=runtime_environment,
            cwd=output_directory,
        )
        with ACTIVE_PROCESSES_LOCK:
            ACTIVE_PROCESSES.add(process)
        try:
            return_code = process.wait()
        finally:
            with ACTIVE_PROCESSES_LOCK:
                ACTIVE_PROCESSES.discard(process)

    if STOP_EVENT.is_set():
        return "failed", f"{item.filename}: 中断されました（部分ファイルはHDD内に残しています）"
    if return_code != 0:
        return "failed", f"{item.filename}: ffmpeg失敗 (終了コード {return_code}, ログ: {ffmpeg_log})"

    validate_external_volume(volume.mount_point, expected=volume)
    valid, detail = verify_mp4(temp_path, stream.duration_seconds)
    if not valid:
        return "failed", f"{item.filename}: ダウンロード後の検証に失敗 ({detail})"
    os.replace(temp_path, final_path)
    return "completed", f"{item.filename}: 完了 ({detail}, {human_bytes(final_path.stat().st_size)})"


def download_one(
    item: ArchiveItem,
    project: str,
    api_key: str,
    max_height: int,
    volume: Volume,
    output_directory: Path,
    state_directory: Path,
    runtime_environment: dict[str, str],
) -> tuple[str, str]:
    if STOP_EVENT.is_set():
        return "failed", f"{item.filename}: 中断されました"
    try:
        stream = resolve_stream(item, project, api_key, max_height)
        return run_ffmpeg(stream, volume, output_directory, state_directory, runtime_environment)
    except Exception as error:
        return "failed", f"{item.filename}: {error}"


def save_state(state_path: Path, state: dict[str, Any], volume: Volume) -> None:
    validate_external_volume(volume.mount_point, expected=volume)
    temporary = safe_child(volume.mount_point, state_path.with_suffix(".json.tmp"))
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(state, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, state_path)


def preflight_streams(
    items: list[ArchiveItem], project: str, api_key: str, max_height: int
) -> tuple[dict[str, StreamInfo], dict[str, str]]:
    streams: dict[str, StreamInfo] = {}
    errors: dict[str, str] = {}

    def inspect(item: ArchiveItem) -> tuple[ArchiveItem, StreamInfo | None, str | None]:
        try:
            return item, resolve_stream(item, project, api_key, max_height), None
        except Exception as error:
            return item, None, str(error)

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(inspect, item) for item in items]
        for index, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            item, stream, error = future.result()
            if stream:
                streams[item.filename] = stream
            else:
                errors[item.filename] = error or "不明なエラー"
            print(f"\r配信情報を確認中: {index}/{len(items)}", end="", flush=True)
    print()
    return streams, errors


def create_runtime_directories(volume: Volume) -> tuple[Path, Path, dict[str, str]]:
    output_directory = safe_child(volume.mount_point, volume.mount_point / OUTPUT_DIRECTORY_NAME)
    if output_directory.exists() and output_directory.is_symlink():
        raise DownloadError(f"保存先がシンボリックリンクのため拒否しました: {output_directory}")
    output_directory.mkdir(parents=False, exist_ok=True)
    output_directory = safe_child(volume.mount_point, output_directory)

    state_directory = safe_child(volume.mount_point, output_directory / STATE_DIRECTORY_NAME)
    state_directory.mkdir(exist_ok=True)
    for name in ("tmp", "logs", "cache"):
        directory = safe_child(volume.mount_point, state_directory / name)
        directory.mkdir(exist_ok=True)

    environment = os.environ.copy()
    environment.update(
        {
            "TMPDIR": str(state_directory / "tmp"),
            "TMP": str(state_directory / "tmp"),
            "TEMP": str(state_directory / "tmp"),
            "XDG_CACHE_HOME": str(state_directory / "cache"),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    return output_directory, state_directory, environment


def self_test() -> None:
    manifest = """#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=6000000,AVERAGE-BANDWIDTH=5000000,RESOLUTION=1920x1080
https://example.invalid/1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3500000,AVERAGE-BANDWIDTH=3000000,RESOLUTION=1280x720
https://example.invalid/720.m3u8
"""
    variants = parse_manifest_variants(manifest)
    assert choose_variant(variants, 1080)["height"] == 1080
    assert choose_variant(variants, 720)["height"] == 720
    item = ArchiveItem(1, "2026-07-23", 1, "1コート", "a" * 32, None, None)
    assert item.filename == "2026-07-23_01.mp4"
    assert extract_court("36コート 和歌山県立体育館") == 36
    print("自己テスト: OK")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="インターハイ2026・バドミントン（7月23〜25日）の全アーカイブを外付けHDDへ保存します。"
    )
    parser.add_argument(
        "--volume",
        help="保存先HDDのボリューム名、または /Volumes/〜 のマウントパス。省略時は自動検出します。",
    )
    parser.add_argument(
        "--max-height",
        type=int,
        choices=(360, 540, 720, 1080),
        default=1080,
        help="保存する最大解像度。既定値: 1080",
    )
    parser.add_argument(
        "--date",
        dest="dates",
        action="append",
        choices=TARGET_DATES,
        help=(
            "対象日を限定します。例: --date 2026-07-23。"
            "複数回指定できます。省略時は7月23〜25日です。"
        ),
    )
    parser.add_argument(
        "--jobs",
        type=int,
        choices=range(1, 37),
        default=2,
        help="同時ダウンロード数（1〜36）。既定値: 2",
    )
    parser.add_argument("--yes", action="store_true", help="最終確認を省略します。")
    parser.add_argument("--check-only", action="store_true", help="HDD・件数・容量だけ確認し、保存しません。")
    parser.add_argument("--self-test", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        self_test()
        return 0
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise DownloadError("ffmpeg / ffprobe が見つかりません。")

    selected_dates = tuple(dict.fromkeys(args.dates or TARGET_DATES))
    selected_dates_label = ", ".join(selected_dates)

    print("=" * 68)
    print(f"インターハイ2026 バドミントン アーカイブ保存（{selected_dates_label}）")
    print("内蔵ストレージには保存しません。外付け物理HDDのみ使用します。")
    print("=" * 68)

    volume = choose_volume(args.volume, args.yes)
    usage = shutil.disk_usage(volume.mount_point)
    print(f"\n保存先HDD: {volume.name}")
    print(f"マウント先: {volume.mount_point}")
    print(f"デバイス: {volume.device_identifier}")
    print(f"ファイルシステム: {volume.filesystem}")
    print(f"現在の空き容量: {human_bytes(usage.free)}")

    print("\nサイトから対象一覧を確認しています…")
    items = load_archive_inventory(selected_dates)
    counts = {date: sum(item.date == date for item in items) for date in selected_dates}
    print(f"対象: {len(items)}本 ({', '.join(f'{date}: {count}本' for date, count in counts.items())})")
    expected_archive_count = sum(EXPECTED_ARCHIVE_COUNTS[date] for date in selected_dates)
    if len(items) != expected_archive_count:
        print(f"警告: 事前確認時の{expected_archive_count}本と現在の件数が異なります。")

    project, api_key = load_player_credentials()
    streams, preflight_errors = preflight_streams(items, project, api_key, args.max_height)
    estimated_bytes = sum(stream.estimated_bytes for stream in streams.values())
    duration_seconds = sum(stream.duration_seconds for stream in streams.values())

    output_directory = safe_child(volume.mount_point, volume.mount_point / OUTPUT_DIRECTORY_NAME)
    existing_count = 0
    existing_bytes = 0
    for filename, stream in streams.items():
        candidate = safe_child(volume.mount_point, output_directory / filename)
        if candidate.exists():
            valid, _ = verify_mp4(candidate, stream.duration_seconds)
            if valid:
                existing_count += 1
                existing_bytes += stream.estimated_bytes
    remaining_estimate = max(0, estimated_bytes - existing_bytes)
    required_free = int(remaining_estimate * ESTIMATE_MARGIN) + MINIMUM_EXTRA_BYTES
    usage = shutil.disk_usage(volume.mount_point)

    print(f"\n取得可能: {len(streams)}本")
    print(f"合計時間: {human_hours(duration_seconds)}")
    print(f"推定容量（{args.max_height}p以下）: {human_bytes(estimated_bytes)}")
    print(f"完了済み: {existing_count}本")
    print(f"今回必要な推定空き容量（余裕込み）: {human_bytes(required_free)}")
    print(f"HDD空き容量: {human_bytes(usage.free)}")
    if preflight_errors:
        print("\n現時点で取得できない動画:")
        for filename, error in sorted(preflight_errors.items()):
            print(f"  - {filename}: {error}")

    if usage.free < required_free:
        raise DownloadError(
            f"HDDの空き容量が不足しています。必要 {human_bytes(required_free)} / 空き {human_bytes(usage.free)}"
        )

    if args.check_only:
        print("\n確認のみで終了しました。ファイルは作成していません。")
        return 0

    print(f"\n保存フォルダ: {output_directory}")
    print("ファイル名例: 2026-07-23_01.mp4")
    if not args.yes:
        answer = input("上記の外付けHDDへダウンロードを開始します。START と入力してください: ").strip()
        if answer != "START":
            print("キャンセルしました。")
            return 0

    validate_external_volume(volume.mount_point, expected=volume)
    output_directory, state_directory, runtime_environment = create_runtime_directories(volume)
    master_log = safe_child(volume.mount_point, state_directory / "download.log")
    state_path = safe_child(volume.mount_point, state_directory / "state.json")
    state: dict[str, Any] = {
        "started_at": dt.datetime.now().astimezone().isoformat(),
        "volume": {
            "name": volume.name,
            "device_identifier": volume.device_identifier,
            "volume_uuid": volume.volume_uuid,
            "mount_point": str(volume.mount_point),
            "filesystem": volume.filesystem,
        },
        "settings": {
            "dates": list(selected_dates),
            "max_height": args.max_height,
            "jobs": args.jobs,
        },
        "completed": [],
        "skipped": [],
        "failed": dict(preflight_errors),
    }
    save_state(state_path, state, volume)
    append_log(
        master_log,
        f"開始: {len(items)}本 / dates={selected_dates_label} / "
        f"最大{args.max_height}p / jobs={args.jobs}",
    )

    caffeinate_process: subprocess.Popen[bytes] | None = None
    caffeinate = shutil.which("caffeinate")
    if caffeinate:
        caffeinate_process = subprocess.Popen(
            [caffeinate, "-dimsu", "-w", str(os.getpid())],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        append_log(master_log, "ダウンロード中の自動スリープを抑止しました。")

    executor = concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs)
    futures: dict[concurrent.futures.Future[tuple[str, str]], ArchiveItem] = {}
    try:
        for item in items:
            future = executor.submit(
                download_one,
                item,
                project,
                api_key,
                args.max_height,
                volume,
                output_directory,
                state_directory,
                runtime_environment,
            )
            futures[future] = item

        for index, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            item = futures[future]
            try:
                status, message = future.result()
            except Exception as error:
                status, message = "failed", f"{item.filename}: {error}"
            print(f"[{index}/{len(futures)}] {message}")
            append_log(master_log, message)
            if status == "completed":
                state["completed"].append(item.filename)
                state["failed"].pop(item.filename, None)
            elif status == "skipped":
                state["skipped"].append(item.filename)
                state["failed"].pop(item.filename, None)
            else:
                state["failed"][item.filename] = message
            save_state(state_path, state, volume)
    except KeyboardInterrupt:
        print("\n中断しています。完了済み動画は次回スキップされます…")
        terminate_active_processes()
        raise
    finally:
        executor.shutdown(wait=True, cancel_futures=True)
        if caffeinate_process and caffeinate_process.poll() is None:
            caffeinate_process.terminate()
            try:
                caffeinate_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                caffeinate_process.kill()

    state["finished_at"] = dt.datetime.now().astimezone().isoformat()
    save_state(state_path, state, volume)
    completed_total = len(set(state["completed"] + state["skipped"]))
    failed_total = len(state["failed"])
    print("\n" + "=" * 68)
    print(f"処理終了: 完了・確認済み {completed_total}本 / 未取得 {failed_total}本")
    print(f"保存先: {output_directory}")
    print(f"状態ファイル: {state_path}")
    print("未取得がある場合は、後日同じスクリプトを再実行してください。")
    print("=" * 68)
    return 0 if failed_total == 0 else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        terminate_active_processes()
        print("\n中断しました。部分ファイルは外付けHDD内だけにあります。", file=sys.stderr)
        raise SystemExit(130)
    except DownloadError as error:
        print(f"\nエラー: {error}", file=sys.stderr)
        print("内蔵ストレージへの保存は行っていません。", file=sys.stderr)
        raise SystemExit(1)
