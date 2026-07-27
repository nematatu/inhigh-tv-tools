#!/usr/bin/env python3
"""2026年インターハイ・バドミントン（7月23〜27日）のアーカイブ保存用。

重要:
  - スクリプト本体以外は、外付け物理ディスクと検証できたボリュームにのみ書き込みます。
  - 内蔵ストレージへのフォールバックは行いません。
  - 完了済みMP4はffprobeで検証し、対話画面の選択肢から除外します。

Finderからダブルクリックするか、Terminalで次のように実行してください。

  ./download_inhigh_2026.command
  ./download_inhigh_2026.command --interactive
  ./download_inhigh_2026.command --volume "HDDの名前"
  ./download_inhigh_2026.command --volume "HDDの名前" --date 2026-07-23 --court 1

既定は最高画質（最大1080p）、同時ダウンロード2本です。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import curses
import dataclasses
import datetime as dt
import io
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
import unicodedata
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
TARGET_DATES = (
    "2026-07-23",
    "2026-07-24",
    "2026-07-25",
    "2026-07-26",
    "2026-07-27",
)
EXPECTED_ARCHIVE_COUNTS = {
    "2026-07-23": 36,
    "2026-07-24": 16,
    "2026-07-25": 36,
    "2026-07-26": 36,
    "2026-07-27": 8,
}
OUTPUT_DIRECTORY_NAME = "inhigh-tv-2026-badminton"
LEGACY_OUTPUT_DIRECTORY_NAMES = (
    "インターハイ2026_バドミントン_7月23-25日",
    "インターハイ2026_バドミントン",
)
STATE_DIRECTORY_NAME = ".inhigh-download"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 Chrome/150 Safari/537.36"
VOLUMES_ROOT = Path("/Volumes")
MINIMUM_EXTRA_BYTES = 10 * 1024**3
ESTIMATE_MARGIN = 1.08


class DownloadError(RuntimeError):
    """安全に処理を続行できない場合の例外。"""


class UserCancelled(RuntimeError):
    """対話画面で利用者がキャンセルした場合の例外。"""


class JapaneseArgumentParser(argparse.ArgumentParser):
    """argparseの固定見出しを日本語で表示する。"""

    def format_usage(self) -> str:
        return super().format_usage().replace("usage:", "使用方法:", 1)

    def format_help(self) -> str:
        return super().format_help().replace("usage:", "使用方法:", 1)

    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        self.exit(2, f"{self.prog}: 引数エラー: {message}\n")


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


@dataclasses.dataclass(frozen=True)
class MenuOption:
    value: str
    label: str


ACTIVE_PROCESSES: set[subprocess.Popen[Any]] = set()
ACTIVE_PROCESSES_LOCK = threading.Lock()
STOP_EVENT = threading.Event()
LOG_LOCK = threading.Lock()
OUTPUT_LOCK = threading.Lock()


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


def clock_time(seconds: int | float) -> str:
    total = max(0, int(float(seconds)))
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours:d}:{minutes:02d}:{secs:02d}"


def parse_ffmpeg_time(value: str) -> float:
    match = re.fullmatch(r"(\d+):(\d{2}):(\d{2}(?:\.\d+)?)", value.strip())
    if not match:
        return 0.0
    return int(match.group(1)) * 3600 + int(match.group(2)) * 60 + float(match.group(3))


def parse_speed_factor(value: str) -> float | None:
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)x\s*", value)
    if not match:
        return None
    factor = float(match.group(1))
    return factor if factor > 0 else None


def estimated_finish_label(
    remaining_seconds: float, now: dt.datetime | None = None
) -> str:
    current = now or dt.datetime.now().astimezone()
    finish = current + dt.timedelta(seconds=max(0.0, remaining_seconds))
    if finish.date() == current.date():
        return finish.strftime("%H:%M頃")
    return finish.strftime("%m/%d %H:%M頃")


def keyboard_multiselect(title: str, options: list[MenuOption]) -> list[str]:
    """j/k・矢印・Spaceで操作する複数選択メニュー。"""
    if not options:
        raise DownloadError(f"選択できる項目がありません: {title}")
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise DownloadError("対話選択にはTerminalが必要です。")

    def run(screen: Any) -> list[str]:
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        screen.keypad(True)
        cursor = 0
        selected: set[str] = set()
        message = ""

        while True:
            height, width = screen.getmaxyx()
            screen.erase()
            visible_rows = max(1, height - 7)
            start = min(max(0, cursor - visible_rows + 1), max(0, len(options) - visible_rows))
            end = min(len(options), start + visible_rows)

            def write(row: int, text: str, attributes: int = 0) -> None:
                if row >= height or width <= 1:
                    return
                try:
                    screen.addnstr(row, 0, text, width - 1, attributes)
                except curses.error:
                    pass

            write(0, title, curses.A_BOLD)
            write(1, "j/k または ↑/↓: 移動   Space: 選択   a: 全選択/解除")
            write(2, "Enter: 確定   g/G: 先頭/末尾   q: キャンセル")
            write(3, f"選択中: {len(selected)}/{len(options)}")

            for row, index in enumerate(range(start, end), start=5):
                option = options[index]
                cursor_mark = ">" if index == cursor else " "
                selected_mark = "x" if option.value in selected else " "
                attributes = curses.A_REVERSE if index == cursor else 0
                write(row, f"{cursor_mark} [{selected_mark}] {option.label}", attributes)

            if message:
                write(height - 1, message, curses.A_BOLD)
            screen.refresh()
            key = screen.get_wch()

            if key in ("j", curses.KEY_DOWN):
                cursor = min(len(options) - 1, cursor + 1)
            elif key in ("k", curses.KEY_UP):
                cursor = max(0, cursor - 1)
            elif key == "g" or key == curses.KEY_HOME:
                cursor = 0
            elif key == "G" or key == curses.KEY_END:
                cursor = len(options) - 1
            elif key == " ":
                value = options[cursor].value
                if value in selected:
                    selected.remove(value)
                else:
                    selected.add(value)
                message = ""
            elif key == "a":
                values = {option.value for option in options}
                selected = set() if selected == values else values
                message = ""
            elif key in ("\n", "\r", curses.KEY_ENTER, 10, 13):
                if selected:
                    return [option.value for option in options if option.value in selected]
                message = "1件以上選択してください。"
            elif key == "q":
                raise UserCancelled("対話選択をキャンセルしました。")

    return curses.wrapper(run)


def interactive_select_dates(
    inventory: list[ArchiveItem], remaining_items: list[ArchiveItem]
) -> tuple[str, ...]:
    options: list[MenuOption] = []
    for date in TARGET_DATES:
        total = sum(item.date == date for item in inventory)
        remaining = sum(item.date == date for item in remaining_items)
        completed = total - remaining
        if remaining > 0:
            options.append(
                MenuOption(
                    date,
                    f"{date}   未完了 {remaining}コート / 完了済み {completed}コート",
                )
            )
    return tuple(keyboard_multiselect("日付を選択", options))


def interactive_select_items(items: list[ArchiveItem]) -> list[ArchiveItem]:
    options = [
        MenuOption(item.filename, f"{item.date}   第{item.court:02d}コート")
        for item in items
    ]
    selected = set(keyboard_multiselect("ダウンロードするコートを選択", options))
    return [item for item in items if item.filename in selected]


class ProgressReporter:
    """TTYでは固定ダッシュボード、非TTYでは間引いた進捗ログを表示する。"""

    def __init__(
        self,
        streams: list[StreamInfo],
        *,
        output: Any | None = None,
        live: bool | None = None,
    ) -> None:
        self._streams = {stream.item.filename: stream for stream in streams}
        self._processed = {filename: 0.0 for filename in self._streams}
        self._speed_factors: dict[str, float] = {}
        self._speed_labels: dict[str, str] = {}
        self._phases = {filename: "待機中" for filename in self._streams}
        self._active: set[str] = set()
        self._terminal: set[str] = set()
        self._completed: set[str] = set()
        self._last_bucket: dict[str, int] = {}
        self._last_phase: dict[str, str] = {}
        self._last_overall_bucket: int | None = None
        self._last_overall_output_at: float | None = None
        self._output = output or sys.stdout
        detected_live = bool(getattr(self._output, "isatty", lambda: False)())
        self._live = detected_live if live is None else live
        self._rendered_lines = 0
        self._last_rendered_at = 0.0
        self._closed = False

    @staticmethod
    def _bar(percent: float, width: int = 24) -> str:
        filled = min(width, int(percent / 100 * width))
        return "█" * filled + "░" * (width - filled)

    @staticmethod
    def _display_width(text: str) -> int:
        width = 0
        for character in text:
            if unicodedata.combining(character):
                continue
            width += 2 if unicodedata.east_asian_width(character) in ("W", "F") else 1
        return width

    @classmethod
    def _fit_line(cls, text: str, width: int) -> str:
        if width <= 0:
            return ""
        if cls._display_width(text) <= width:
            return text
        if width == 1:
            return "…"
        result: list[str] = []
        used = 0
        limit = width - 1
        for character in text:
            character_width = (
                0
                if unicodedata.combining(character)
                else 2 if unicodedata.east_asian_width(character) in ("W", "F") else 1
            )
            if used + character_width > limit:
                break
            result.append(character)
            used += character_width
        return "".join(result) + "…"

    def _terminal_size(self) -> os.terminal_size:
        try:
            return os.get_terminal_size(self._output.fileno())
        except (AttributeError, OSError, ValueError, io.UnsupportedOperation):
            return shutil.get_terminal_size(fallback=(120, 24))

    def _overall_values(self) -> tuple[float, tuple[float, float] | None]:
        total_duration = sum(stream.duration_seconds for stream in self._streams.values())
        processed = sum(self._processed.values())
        percent = min(100.0, processed / total_duration * 100) if total_duration > 0 else 100.0
        return percent, self._overall_eta()

    def _overall_eta(self) -> tuple[float, float] | None:
        remaining = sum(
            max(0.0, stream.duration_seconds - self._processed[filename])
            for filename, stream in self._streams.items()
            if filename not in self._terminal
        )
        aggregate_speed = sum(
            self._speed_factors.get(filename, 0.0)
            for filename in self._active
            if filename not in self._terminal
            and self._processed[filename] < self._streams[filename].duration_seconds
        )
        if remaining <= 0:
            return 0.0, 0.0
        if aggregate_speed <= 0:
            return None
        return remaining, remaining / aggregate_speed

    def _overall_status(self) -> str:
        percent, eta = self._overall_values()
        status = (
            f"[全体] [{self._bar(percent, width=16)}] {percent:5.1f}%"
            f" | 完了 {len(self._completed)}/{len(self._streams)}"
        )
        if eta is None:
            status += " | 推定終了: 実測速度を計算中"
        else:
            _, remaining_wall_seconds = eta
            status += (
                f" | 残り {clock_time(remaining_wall_seconds)}"
                f" | 終了予定 {estimated_finish_label(remaining_wall_seconds)}"
            )
        return status

    def _stream_status_parts(self, filename: str) -> tuple[str, str]:
        stream = self._streams[filename]
        processed = self._processed[filename]
        percent = (
            min(100.0, processed / stream.duration_seconds * 100)
            if stream.duration_seconds > 0
            else 100.0
        )
        status = (
            f"[{filename}] [{self._bar(percent, width=12)}] {percent:5.1f}%"
            f" | {self._phases[filename]}"
        )
        timing = (
            f"  処理 {clock_time(processed)}/{clock_time(stream.duration_seconds)}"
        )
        speed_label = self._speed_labels.get(filename, "")
        speed_factor = self._speed_factors.get(filename)
        if speed_label and speed_label != "N/A":
            timing += f" | {speed_label}"
        if speed_factor is not None and percent < 100:
            remaining_wall = max(0.0, stream.duration_seconds - processed) / speed_factor
            timing += (
                f" | 残り {clock_time(remaining_wall)}"
                f" | 完了予定 {estimated_finish_label(remaining_wall)}"
            )
        return status, timing

    def _stream_status(self, filename: str) -> str:
        status, timing = self._stream_status_parts(filename)
        return f"{status} | {timing.strip()}"

    def _dashboard_lines(self) -> list[str]:
        size = self._terminal_size()
        active = [
            filename
            for filename in self._streams
            if filename in self._active and filename not in self._terminal
        ]
        max_active_items = max(1, (size.lines - 4) // 2)
        visible_active = active[:max_active_items]
        lines = [
            "進捗（この領域を更新します。Ctrl+Cで中断）",
            self._overall_status(),
        ]
        for filename in visible_active:
            lines.extend(self._stream_status_parts(filename))
        queued = len(self._streams) - len(active) - len(self._terminal)
        hidden = len(active) - len(visible_active)
        details: list[str] = []
        if queued > 0:
            details.append(f"待機 {queued}本")
        if hidden > 0:
            details.append(f"画面外で処理中 {hidden}本")
        if details:
            lines.append("  " + " / ".join(details))
        width = max(1, size.columns - 1)
        return [self._fit_line(line, width) for line in lines]

    def _clear_live_locked(self) -> None:
        if not self._live or self._rendered_lines <= 0:
            return
        for _ in range(self._rendered_lines):
            self._output.write("\x1b[1A\r\x1b[2K")
        self._rendered_lines = 0

    def _render_live_locked(self, *, force: bool = False) -> None:
        if not self._live or self._closed:
            return
        now = time.monotonic()
        if not force and self._last_rendered_at and now - self._last_rendered_at < 0.2:
            return
        self._clear_live_locked()
        lines = self._dashboard_lines()
        for line in lines:
            self._output.write(f"\r\x1b[2K{line}\n")
        self._output.flush()
        self._rendered_lines = len(lines)
        self._last_rendered_at = now

    def _emit_non_live_locked(
        self,
        filename: str,
        *,
        force: bool,
        terminal: bool,
        phase_changed: bool,
        bucket: int,
    ) -> None:
        should_print_file = (
            force
            or phase_changed
            or self._last_bucket.get(filename) != bucket
        )
        if should_print_file:
            self._last_bucket[filename] = bucket
            print(self._stream_status(filename), file=self._output, flush=True)

        percent, _ = self._overall_values()
        overall_bucket = int(percent // 5)
        now = time.monotonic()
        should_print_overall = (
            self._last_overall_output_at is None
            or terminal
            or self._last_overall_bucket != overall_bucket
            or now - self._last_overall_output_at >= 60
        )
        if should_print_overall:
            print(self._overall_status(), file=self._output, flush=True)
            self._last_overall_output_at = now
            self._last_overall_bucket = overall_bucket

    def update(
        self,
        stream: StreamInfo,
        phase: str,
        *,
        processed_seconds: float | None = None,
        speed: str = "",
        force: bool = False,
        terminal: bool = False,
        completed: bool = False,
    ) -> None:
        filename = stream.item.filename
        percent: float | None = None
        if processed_seconds is not None and stream.duration_seconds > 0:
            percent = min(100.0, max(0.0, processed_seconds / stream.duration_seconds * 100))
        bucket = int(percent // 5) if percent is not None else -1

        with OUTPUT_LOCK:
            if self._closed:
                return
            if filename not in self._terminal:
                self._active.add(filename)
            if processed_seconds is not None:
                self._processed[filename] = min(
                    stream.duration_seconds,
                    max(self._processed.get(filename, 0.0), processed_seconds),
                )
            speed_factor = parse_speed_factor(speed)
            if speed_factor is not None:
                self._speed_factors[filename] = speed_factor
                self._speed_labels[filename] = speed.strip()
            if terminal:
                self._terminal.add(filename)
                self._active.discard(filename)
                self._speed_factors.pop(filename, None)
            if completed:
                self._completed.add(filename)
            phase_changed = self._last_phase.get(filename) != phase
            self._phases[filename] = phase
            self._last_phase[filename] = phase
            if self._live:
                self._render_live_locked(force=force or terminal or phase_changed)
            else:
                self._emit_non_live_locked(
                    filename,
                    force=force,
                    terminal=terminal,
                    phase_changed=phase_changed,
                    bucket=bucket,
                )

    def event(self, message: str) -> None:
        """固定表示を一時消去し、完了・失敗などの確定イベントを1行残す。"""
        with OUTPUT_LOCK:
            if self._live and not self._closed:
                self._clear_live_locked()
            print(message, file=self._output, flush=True)
            if self._live and not self._closed:
                self._render_live_locked(force=True)

    def close(self) -> None:
        """固定表示を消去して、後続の通常出力が崩れない状態へ戻す。"""
        with OUTPUT_LOCK:
            if self._closed:
                return
            self._clear_live_locked()
            self._output.flush()
            self._closed = True


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


def output_directory_for(volume: Volume, *, migrate_legacy: bool = False) -> Path:
    """ASCII名を使用し、実行開始時だけ旧フォルダを同一HDD内で改名する。"""
    current = safe_child(volume.mount_point, volume.mount_point / OUTPUT_DIRECTORY_NAME)
    legacy_directories = [
        safe_child(volume.mount_point, volume.mount_point / name)
        for name in LEGACY_OUTPUT_DIRECTORY_NAMES
    ]
    existing_legacy = [path for path in legacy_directories if path.exists()]
    if current.exists() and not current.is_dir():
        raise DownloadError(f"保存先と同名のファイルがあるため停止しました: {current}")
    if current.exists() and existing_legacy:
        raise DownloadError(
            "保存フォルダが新旧両方に存在します。内容を自動統合できないため停止しました: "
            f"{current} / {', '.join(map(str, existing_legacy))}"
        )
    if len(existing_legacy) > 1:
        raise DownloadError(
            "旧保存フォルダが複数存在します。内容を自動統合できないため停止しました: "
            f"{', '.join(map(str, existing_legacy))}"
        )
    if not existing_legacy:
        return current

    legacy = existing_legacy[0]
    if not legacy.is_dir() or legacy.is_symlink():
        raise DownloadError(f"旧保存フォルダを安全に確認できません: {legacy}")
    if not migrate_legacy:
        return legacy

    validate_external_volume(volume.mount_point, expected=volume)
    move = subprocess.run(
        ["/bin/mv", "-n", str(legacy), str(current)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if move.returncode != 0 or legacy.exists() or not current.is_dir():
        detail = move.stderr.strip() or "保存先がすでに存在する可能性があります"
        raise DownloadError(
            f"旧保存フォルダをASCII名へ変更できませんでした: {legacy} -> {current} ({detail})"
        )
    print(f"旧保存フォルダを移行しました: {legacy.name} -> {current.name}")
    return safe_child(volume.mount_point, current)


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
        if expected_duration:
            return False, f"動画が短すぎます: {duration:.1f}秒（期待値 {expected_duration:.1f}秒）"
        return False, f"動画が短すぎます: {duration:.1f}秒"
    return True, f"{duration:.1f}秒"


def scan_completed_archives(
    items: list[ArchiveItem], volume: Volume
) -> tuple[dict[str, str], dict[str, str]]:
    """HDD上の完成済みMP4と、同名だが不完全なファイルを読み取り専用で確認する。"""
    output_directory = output_directory_for(volume)
    if not output_directory.exists():
        return {}, {}
    if not output_directory.is_dir() or output_directory.is_symlink():
        raise DownloadError(f"保存フォルダを安全に確認できません: {output_directory}")

    candidates: list[tuple[ArchiveItem, Path]] = []
    for item in items:
        candidate = safe_child(volume.mount_point, output_directory / item.filename)
        if candidate.exists():
            candidates.append((item, candidate))
    if not candidates:
        return {}, {}

    completed: dict[str, str] = {}
    incomplete: dict[str, str] = {}

    def inspect(entry: tuple[ArchiveItem, Path]) -> tuple[str, bool, str]:
        item, path = entry
        valid, detail = verify_mp4(path)
        return item.filename, valid, detail

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(candidates))) as executor:
        futures = [executor.submit(inspect, entry) for entry in candidates]
        for index, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            filename, valid, detail = future.result()
            target = completed if valid else incomplete
            target[filename] = detail
            print(f"\rHDD上のMP4を確認中: {index}/{len(candidates)}", end="", flush=True)
    print()
    return completed, incomplete


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
    progress: ProgressReporter,
) -> tuple[str, str]:
    item = stream.item
    final_path = safe_child(volume.mount_point, output_directory / item.filename)
    temp_path = safe_child(volume.mount_point, state_directory / "tmp" / f"{item.filename}.part.mp4")
    ffmpeg_log = safe_child(volume.mount_point, state_directory / "logs" / f"{item.filename}.log")

    if final_path.exists():
        valid, detail = verify_mp4(final_path, stream.duration_seconds)
        if valid:
            progress.update(
                stream,
                "完了済み（スキップ）",
                processed_seconds=stream.duration_seconds,
                force=True,
                terminal=True,
                completed=True,
            )
            return "skipped", f"{item.filename}: 完了済み ({detail})"
        progress.update(
            stream,
            "停止（同名の不完全ファイルあり）",
            force=True,
            terminal=True,
        )
        return "failed", f"{item.filename}: 同名の不完全なファイルがあります。上書きせず停止 ({detail})"

    validate_external_volume(volume.mount_point, expected=volume)
    progress.update(stream, "ffmpeg準備中", processed_seconds=0, force=True)
    command = [
        shutil.which("ffmpeg") or "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "warning",
        "-nostats",
        "-stats_period",
        "1",
        "-progress",
        "pipe:1",
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
            stdout=subprocess.PIPE,
            stderr=log_handle,
            env=runtime_environment,
            cwd=output_directory,
            text=True,
            bufsize=1,
        )
        with ACTIVE_PROCESSES_LOCK:
            ACTIVE_PROCESSES.add(process)
        try:
            processed_seconds = 0.0
            speed = ""
            if process.stdout is None:
                raise DownloadError("ffmpegの進捗出力を取得できませんでした。")
            for raw_line in process.stdout:
                key, separator, value = raw_line.strip().partition("=")
                if not separator:
                    continue
                if key == "out_time":
                    processed_seconds = parse_ffmpeg_time(value)
                elif key == "speed":
                    speed = value
                elif key == "progress":
                    if value == "end":
                        progress.update(
                            stream,
                            "データ取得完了・ffmpeg終了確認中",
                            processed_seconds=stream.duration_seconds,
                            speed=speed,
                            force=True,
                        )
                    else:
                        progress.update(
                            stream,
                            "ダウンロード＋MP4作成中（ffmpeg）",
                            processed_seconds=min(processed_seconds, stream.duration_seconds * 0.999),
                            speed=speed,
                        )
            return_code = process.wait()
        finally:
            with ACTIVE_PROCESSES_LOCK:
                ACTIVE_PROCESSES.discard(process)

    if STOP_EVENT.is_set():
        progress.update(stream, "中断", force=True, terminal=True)
        return "failed", f"{item.filename}: 中断されました（部分ファイルはHDD内に残しています）"
    if return_code != 0:
        progress.update(
            stream,
            f"ffmpeg失敗（終了コード {return_code}）",
            force=True,
            terminal=True,
        )
        return "failed", f"{item.filename}: ffmpeg失敗 (終了コード {return_code}, ログ: {ffmpeg_log})"

    validate_external_volume(volume.mount_point, expected=volume)
    progress.update(
        stream,
        "ffmpeg完了・MP4検証中",
        processed_seconds=stream.duration_seconds,
        force=True,
    )
    valid, detail = verify_mp4(temp_path, stream.duration_seconds)
    if not valid:
        progress.update(
            stream,
            "検証失敗",
            processed_seconds=stream.duration_seconds,
            force=True,
            terminal=True,
        )
        return "failed", f"{item.filename}: ダウンロード後の検証に失敗 ({detail})"
    os.replace(temp_path, final_path)
    progress.update(
        stream,
        "完了",
        processed_seconds=stream.duration_seconds,
        force=True,
        terminal=True,
        completed=True,
    )
    return "completed", f"{item.filename}: 完了 ({detail}, {human_bytes(final_path.stat().st_size)})"


def download_one(
    stream: StreamInfo,
    volume: Volume,
    output_directory: Path,
    state_directory: Path,
    runtime_environment: dict[str, str],
    progress: ProgressReporter,
) -> tuple[str, str]:
    item = stream.item
    if STOP_EVENT.is_set():
        return "failed", f"{item.filename}: 中断されました"
    try:
        progress.update(stream, "開始準備中", force=True)
        return run_ffmpeg(
            stream,
            volume,
            output_directory,
            state_directory,
            runtime_environment,
            progress,
        )
    except Exception as error:
        progress.update(stream, f"失敗: {error}", force=True, terminal=True)
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
    output_directory = output_directory_for(volume, migrate_legacy=True)
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
    assert parse_ffmpeg_time("08:15:30.500000") == 29730.5
    assert parse_ffmpeg_time("invalid") == 0
    assert parse_speed_factor("1.25x") == 1.25
    assert parse_speed_factor("N/A") is None
    test_now = dt.datetime(2026, 7, 27, 20, 0, tzinfo=dt.timezone(dt.timedelta(hours=9)))
    assert estimated_finish_label(3600, test_now) == "21:00頃"
    assert estimated_finish_label(36000, test_now) == "07/28 06:00頃"
    assert MenuOption("2026-07-23", "7月23日").value == "2026-07-23"
    assert OUTPUT_DIRECTORY_NAME.isascii()
    assert re.fullmatch(r"[a-z0-9-]+", OUTPUT_DIRECTORY_NAME)
    test_stream = StreamInfo(item, "https://example.invalid/video.m3u8", 100, 1920, 1080, 1)
    live_output = io.StringIO()
    live_reporter = ProgressReporter([test_stream], output=live_output, live=True)
    live_reporter.update(
        test_stream,
        "ダウンロード中",
        processed_seconds=10,
        speed="2.00x",
        force=True,
    )
    live_reporter.update(test_stream, "ダウンロード中", processed_seconds=20, speed="2.00x")
    live_reporter.event("[1/1] テスト完了")
    live_reporter.close()
    assert "\x1b[1A" in live_output.getvalue()
    assert "[1/1] テスト完了" in live_output.getvalue()
    plain_output = io.StringIO()
    plain_reporter = ProgressReporter([test_stream], output=plain_output, live=False)
    plain_reporter.update(test_stream, "ダウンロード中", processed_seconds=10, force=True)
    plain_reporter.close()
    assert "\x1b[" not in plain_output.getvalue()
    print("自己テスト: OK")


def parse_args() -> argparse.Namespace:
    parser = JapaneseArgumentParser(
        add_help=False,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "インターハイ2026・バドミントン（7月23〜27日）のアーカイブを、\n"
            "内蔵ストレージを使用せず、外付け物理HDDへMP4で保存します。"
        ),
        epilog="""対話画面の操作:
  j / k または ↑ / ↓   カーソル移動
  Space                  選択・選択解除
  a                      全選択・全解除
  Enter                  選択を確定
  q                      キャンセル

実行例:
  対話形式で選ぶ:
    ./download_inhigh_2026.command --interactive --jobs 2

  7月23日の第1・第2コートを指定する:
    ./download_inhigh_2026.command --date 2026-07-23 --court 1 --court 2 --jobs 2

  保存せずに配信情報・必要容量だけ確認する:
    ./download_inhigh_2026.command --check-only --yes

補足:
  保存フォルダ名は inhigh-tv-2026-badminton です。
  旧版の日本語名フォルダは、実際のダウンロード開始時だけASCII名へ変更されます。
  Terminal上の進捗は固定領域を書き換え、完了・失敗などの確定結果だけを履歴に残します。
  完成済みMP4は検証後に選択肢から除外されます。
  Ctrl+Cで中断した部分ファイルは外付けHDD内に残り、再選択時は最初から上書きされます。""",
    )
    parser._optionals.title = "オプション"
    parser.add_argument(
        "-h",
        "--help",
        action="help",
        help="この日本語ヘルプを表示して終了します。",
    )
    parser.add_argument(
        "--volume",
        help="保存先HDDのボリューム名、または /Volumes/〜 のマウントパス。省略時は自動検出します。",
    )
    parser.add_argument(
        "-i",
        "--interactive",
        action="store_true",
        help=(
            "日付とコートをj/k・矢印・Spaceで複数選択します。"
            "--date/--courtとの併用時は未指定側だけ選択します。"
        ),
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
            "複数回指定できます。省略時は7月23〜27日です。"
        ),
    )
    parser.add_argument(
        "--court",
        dest="courts",
        action="append",
        type=int,
        choices=range(1, 100),
        metavar="番号",
        help="対象コートを限定します。例: --court 1。複数回指定できます。",
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
    arguments = sys.argv[1:]
    if arguments in (["help"], ["ヘルプ"]):
        arguments = ["--help"]
    return parser.parse_args(arguments)


def main() -> int:
    args = parse_args()
    if args.self_test:
        self_test()
        return 0
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise DownloadError("ffmpeg / ffprobe が見つかりません。")
    if args.interactive and not sys.stdin.isatty():
        raise DownloadError("--interactive は対話可能なTerminalで実行してください。")

    print("=" * 68)
    print("インターハイ2026 バドミントン アーカイブ保存CLI")
    print("内蔵ストレージには保存しません。外付け物理HDDのみ使用します。")
    print("=" * 68)

    inventory_dates = tuple(dict.fromkeys(args.dates or TARGET_DATES))
    inventory_dates_label = ", ".join(inventory_dates)
    print(f"\nサイトから対象一覧を確認しています…（{inventory_dates_label}）")
    inventory = load_archive_inventory(inventory_dates)
    inventory_counts = {date: sum(item.date == date for item in inventory) for date in inventory_dates}
    print(
        f"サイト掲載: {len(inventory)}本 "
        f"({', '.join(f'{date}: {count}本' for date, count in inventory_counts.items())})"
    )
    expected_archive_count = sum(EXPECTED_ARCHIVE_COUNTS[date] for date in inventory_dates)
    if len(inventory) != expected_archive_count:
        print(f"警告: 事前確認時の{expected_archive_count}本と現在の件数が異なります。")

    volume = choose_volume(args.volume, args.yes)
    usage = shutil.disk_usage(volume.mount_point)
    print(f"\n保存先HDD: {volume.name}")
    print(f"マウント先: {volume.mount_point}")
    print(f"デバイス: {volume.device_identifier}")
    print(f"ファイルシステム: {volume.filesystem}")
    print(f"現在の空き容量: {human_bytes(usage.free)}")

    print("\nすでに保存されているMP4を確認しています…")
    completed_files, incomplete_files = scan_completed_archives(inventory, volume)
    remaining_inventory = [item for item in inventory if item.filename not in completed_files]
    print(f"完了済み（選択肢から除外）: {len(completed_files)}本")
    if incomplete_files:
        print("同名ですが完成済みと確認できないファイル:")
        for filename, detail in sorted(incomplete_files.items()):
            print(f"  - {filename}: {detail}")

    if not remaining_inventory:
        print("\n対象範囲の動画はすべてダウンロード済みです。")
        return 0

    if args.dates:
        selected_dates = tuple(dict.fromkeys(args.dates))
    elif args.interactive:
        selected_dates = interactive_select_dates(inventory, remaining_inventory)
    else:
        selected_dates = TARGET_DATES
    selected_dates_label = ", ".join(selected_dates)
    date_items = [item for item in remaining_inventory if item.date in selected_dates]

    if args.courts:
        selected_courts: list[int] | None = list(dict.fromkeys(args.courts))
        items = [item for item in date_items if item.court in selected_courts]
    elif args.interactive:
        selected_courts = None
        items = interactive_select_items(date_items)
    else:
        selected_courts = None
        items = date_items

    if not items:
        requested = [
            item
            for item in inventory
            if item.date in selected_dates
            and (selected_courts is None or item.court in selected_courts)
        ]
        if requested and all(item.filename in completed_files for item in requested):
            print("\n指定した動画はすべてダウンロード済みです。")
            return 0
        raise DownloadError("指定した日付・コートに未完了のアーカイブがありません。")

    print("\n選択結果（完了済みは除外済み）:")
    for date in selected_dates:
        courts = [item.court for item in items if item.date == date]
        if courts:
            print(f"  {date}: {len(courts)}本（コート {', '.join(map(str, courts))}）")

    project, api_key = load_player_credentials()
    streams, preflight_errors = preflight_streams(items, project, api_key, args.max_height)
    estimated_bytes = sum(stream.estimated_bytes for stream in streams.values())
    duration_seconds = sum(stream.duration_seconds for stream in streams.values())

    existing_output_directory = output_directory_for(volume)
    output_directory = safe_child(volume.mount_point, volume.mount_point / OUTPUT_DIRECTORY_NAME)
    required_free = int(estimated_bytes * ESTIMATE_MARGIN) + MINIMUM_EXTRA_BYTES
    usage = shutil.disk_usage(volume.mount_point)

    print(f"\n取得可能: {len(streams)}本")
    print(f"合計時間: {human_hours(duration_seconds)}")
    print(f"推定容量（{args.max_height}p以下）: {human_bytes(estimated_bytes)}")
    selected_completed_count = sum(
        item.date in selected_dates and item.filename in completed_files for item in inventory
    )
    print(f"選択した日付内で除外した完了済み: {selected_completed_count}本")
    print(f"今回必要な推定空き容量（余裕込み）: {human_bytes(required_free)}")
    print(f"HDD空き容量: {human_bytes(usage.free)}")
    print("進捗率はffmpegが処理した動画時間から算出する目安です。")
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
        return 0 if streams else 2

    if not streams:
        raise DownloadError("選択した動画には、現在ダウンロード可能な配信情報がありません。")

    if existing_output_directory != output_directory:
        print(
            "旧保存フォルダを検出しました。ダウンロード開始時に、途中ファイルを保持したまま"
            f" {output_directory.name} へ変更します。"
        )
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
            "courts": sorted({item.court for item in items}),
            "items": [item.filename for item in items],
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

    caffeinate_process: subprocess.Popen[Any] | None = None
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
    progress = ProgressReporter(list(streams.values()))
    try:
        for item in items:
            stream = streams.get(item.filename)
            if stream is None:
                continue
            future = executor.submit(
                download_one,
                stream,
                volume,
                output_directory,
                state_directory,
                runtime_environment,
                progress,
            )
            futures[future] = item

        for index, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            item = futures[future]
            try:
                status, message = future.result()
            except Exception as error:
                status, message = "failed", f"{item.filename}: {error}"
            progress.event(f"[{index}/{len(futures)}] {message}")
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
        progress.close()
        print("中断しています。完了済み動画は次回スキップされます…")
        terminate_active_processes()
        raise
    finally:
        executor.shutdown(wait=True, cancel_futures=True)
        progress.close()
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
    except UserCancelled as error:
        print(f"\n{error}")
        raise SystemExit(0)
    except KeyboardInterrupt:
        terminate_active_processes()
        print("\n中断しました。部分ファイルは外付けHDD内だけにあります。", file=sys.stderr)
        raise SystemExit(130)
    except DownloadError as error:
        print(f"\nエラー: {error}", file=sys.stderr)
        print("内蔵ストレージへの保存は行っていません。", file=sys.stderr)
        raise SystemExit(1)
