# Investigations & Plans Index

このディレクトリ群には、Madini Archive の主要な調査・設計レポートが保管されている。新しい改修に着手する前に、関連レポートを読んで前提と判断ポイントを把握すること。

## 読む順序

### 1. `rendering-framework-2026-04-30.md` (`docs/investigations/`)

claude ソース表示の「内的独白の折りたたみブロック化」機能の判定ロジック調査と、ソース×モデル別レンダリング設定フレームワークの設計提案。Bug A（数式の言語誤判定）と Bug B（日本語応答の誤折りたたみ）の現象記述、`MessageRenderProfile` の発見、および 4 案の設計比較を含む。

### 2. `importer-migration-2026-04-30.md` (`docs/investigations/`)

Python importer から Swift importer への完全移行の作業量見積もり。Swift 側の既存資産（約 60% 完成）、Python の規模、3 戦略（Swift 完全移行 / DB 再生成 / Python 延命）の比較。**結論: 戦略 C（Python core を生かす）を採用**。core + skinnable-shell アーキテクチャの根拠が記載されている。

### 3. `thinking-preservation-2026-04-30.md` (`docs/plans/`)

戦略 C を前提とした実装計画。`messages.content_json` 列追加、Python parser での thinking 抽出、Swift 側の構造ベース render、既存 archive.db の backfill、Phase 0〜6 の依存関係と工数。直近の Bug B 解決ロードマップ。

## 関連方針

- **アーキテクチャ宣言**: Python core は永続的な portable 土台、GUI 層は着せ替え可能なシェル（SwiftUI Mac / iOS / 将来 Windows）
- **原本保全**: `raw_sources.raw_text` は無傷、新形式は raw_sources から導出可能
- **後方互換**: 既存 reader（Python GUI / 旧 Swift / iOS）が壊れない設計

詳細は `AGENTS.md` の Core Principles と上記 3 レポートを参照。
