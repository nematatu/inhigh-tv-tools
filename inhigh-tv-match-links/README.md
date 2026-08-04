# インハイTV 試合リンク集

2026年インターハイ・バドミントンについて、BIRD SCOREの試合情報とインハイTV公式アーカイブを対応付ける、独立した拡張機能・静的リンク集です。

既存の `../inhigh-tv-skip-extension/` とは別のプロジェクトです。既存拡張のファイルは変更しません。

## 構成

- `extension/`: BIRD SCOREへ「動画を見る」を追加し、インハイTVで指定秒へ移動するManifest V3拡張
- `site/`: 試合検索・リンク一覧の静的ページ
- `tools/build-data.mjs`: BIRD SCORE公開JSONとインハイTV公開API/HLSから対応データを再生成
- `data/`: 生成した対応データの正本

## データ生成

Node.js 18以降で次を実行します。

```bash
npm run build:data
```

生成処理は、BIRD SCOREの試合開始時刻と、インハイTVのHLSに含まれる `EXT-X-PROGRAM-DATE-TIME` を使って開始秒を計算します。署名付きHLS URLやAPIキーは生成データへ保存しません。

試合が未実施、開始時刻なし、アーカイブのメディアID不正などの場合は、リンクを有効化せず `unavailable` として記録します。推測で秒数を埋めません。

## 静的ページ

```bash
npm run serve
```

ブラウザで `http://localhost:8080/` を開きます。静的ページから公式アーカイブへ移動して指定秒へ自動移動するには、同梱拡張を導入してください。

## 拡張機能の導入

Chrome / Edgeで `chrome://extensions` または `edge://extensions` を開き、デベロッパーモードを有効にして `extension/` を「パッケージ化されていない拡張機能」として読み込みます。

拡張は次の公式ページだけを対象にします。

- `https://www.birdscore.live/web/interhigh-2026-wakayama-team/*`
- `https://www.birdscore.live/web/interhigh-2026-wakayama-Individual/*`
- `https://inhightv.sportsbull.jp/summer/archive/*`

Android Chromeの拡張機能対応やiOS Safari Web Extensionの配布は、この独立プロジェクトのコードとは別に端末ごとのパッケージ化が必要です。

## 動画リンクの扱い

リンク先はインハイTV公式アーカイブページです。動画ファイルやHLSプレイリストをこのプロジェクトから再配信しません。
