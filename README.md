# inhigh-tv-tools

インハイTVの視聴と個人利用のアーカイブ管理を補助する、非公式ツール集です。

## 内容

### `downloader/`

2026年インターハイ・バドミントンの長尺アーカイブを、外付け物理HDDへMP4として保存するmacOS向けスクリプトです。

- 対象日を `--date` で1日または複数日指定
- `--date` 省略時は2026年7月23日・24日・25日の全日程
- 最大1080p
- 1〜36本の並列ダウンロード
- 完成済みMP4を検証してスキップ
- 一時ファイル、ログ、状態ファイルも外付けHDD内へ保存
- 内蔵ストレージへのフォールバックを拒否

必要なもの：macOS、Python 3、FFmpeg / FFprobe。

```bash
cd downloader
./download_inhigh_2026.command \
  --volume '/Volumes/HDDの名前' \
  --date 2026-07-23 \
  --jobs 12
```

確認だけ行う場合は `--check-only` を追加します。

### `inhigh-tv-skip-extension/`

インハイTVのStreaks Playerへ「戻る」「進む」ボタンと左右矢印キー操作を追加する、Chrome / Edge向けManifest V3拡張機能です。

- 初期値10秒、1〜300秒で変更可能
- 5・10・15・30秒プリセット
- `←` で戻る、`→` で進む
- 全画面対応
- 広告表示中は本編の再生位置を変更しない

導入手順は [`inhigh-tv-skip-extension/README.md`](inhigh-tv-skip-extension/README.md) を参照してください。

## 注意

本リポジトリはインハイTVおよびSPORTS BULLの公式ツールではありません。対象サイトの利用規約、著作権、配信権、保存や利用に必要な権限を確認し、許可された範囲で使用してください。サイト側の仕様変更により動作しなくなる可能性があります。

動画ファイルとダウンロード途中ファイルはGit管理対象外です。
