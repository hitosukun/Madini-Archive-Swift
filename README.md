# Madini Archive

LLM 会話ログ（Claude / ChatGPT / Gemini）の長期蓄積と再閲覧のためのローカル archive viewer。

[English README](./README.en.md)

## なぜ作ったか

LLM との会話ログは、複数のサービス（ChatGPT、Claude、Gemini）に分散して、それぞれのアプリの中で蓄積されていきます。各サービスの検索機能では遡りきれない、共通の検索もできない、サービスが終了したら消える可能性がある — そういう状況に対して、自分の会話ログを「自分の手元の SQLite ファイル一つ」に統合して、長期的に読み返せる形にしておく、というのがこのプロジェクトの動機です。

執筆や整形のためのツール（Obsidian など）はすでにあるので、Madini Archive は **読むこと・検索すること・遡ること** に特化しています。インポートした原本は変更せず、派生レイヤーで整形・正規化を扱います。

## このリポジトリの構成

このリポジトリは mono-repo です。次の 2 つのコンポーネントが同じツリーで一緒に進化します。

- `Sources/` — **macOS SwiftUI app**（canonical な user-facing 実装）
- `Python/` — **Python importer core**（provider export JSON を `archive.db` に書き込むワーカー）

Swift app は `archive.db` に対して **read-only** で動作し、SQLite schema を所有します。Python importer は schema に合わせて更新される従属コンポーネントで、Swift 側からのドラッグ＆ドロップで子プロセスとして起動されます。

## 設計思想

- **Preserve originals** — text-based import は raw source を保持する。normalized layer は派生としてのみ扱う
- **Local-first** — ローカル SQLite で完結。クラウド sync を前提にしない
- **Portable formats** — SQL / JSON / Markdown / HTML を優先。閉じた独自フォーマットを増やさない
- **Scale resistance** — 10x / 100x のログ量増加を前提に、indexed / paginated / FTS5 ベースの参照経路を選ぶ
- **Support human judgment** — 自動評価や自動要約より、再読・比較・再構成を支援する

詳細な規約は [AGENTS.md](./AGENTS.md) を参照。

## コーディングAIで改造したい人へ

このリポジトリは、Claude Code / Cursor / Codex 等のコーディングAIで改造することを想定して設計されています。

- **`AGENTS.md` を最初にAIに読ませてください。** リポジトリ全体の設計ルール（レイヤー分離、Repository protocol、Window Model、Localization、Reader Typography 等）が記録されています。これを読ませた上で改造指示を出すと、設計の境界を尊重した実装が返ってきやすくなります。
- **AI に直接依頼する前に、要件を AI と一緒に固めることを推奨します。** コーディングAIは指示を器用に実装してしまうため、大局的な方針が間違っていてもそのまま動くものを作ってしまうことがあります。先に普通のチャット LLM とブレストして、何を作るかを言語化してから、コーディングAI に渡すと事故が減ります。
- **コーディングAI と人間の間に、もう一段チャット LLM を挟むワークフローも有効です。** コーディングAI からの細かい質問を、チャット LLM に「平たい言葉に翻訳して」と頼んで判断し、判断結果を「コーディングAI 向けの専門用語のプロンプトに書き戻して」と頼んで返す、という三層構造です。

## ビルドと実行

### CLI (Swift Package Manager)

日常開発・テスト用。

```sh
swift build
swift test
open .build/debug/MadiniArchive
```

### Xcode

```sh
open Package.swift
```

Scheme を `MadiniArchive` に設定して Run (Cmd+R)。SwiftUI Preview (`#Preview`) も利用可能。

### 配布用 `.app` をビルドする

`xcodegen` で `project.yml` から `Madini Archive.xcodeproj` を生成し、`xcodebuild` で Release ビルドする。`.xcodeproj` は git 管理外。

```sh
brew install xcodegen                      # 初回のみ
xcodegen generate                          # project.yml → .xcodeproj
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project "Madini Archive.xcodeproj" \
             -scheme "Madini Archive" \
             -configuration Release \
             -derivedDataPath build/derived build
```

成果物:
`build/derived/Build/Products/Release/Madini Archive.app`

インストール:

```sh
rm -rf "/Applications/Madini Archive.app"
cp -R "build/derived/Build/Products/Release/Madini Archive.app" /Applications/
```

### 動作要件

- macOS 14 Sonoma+
- Xcode 15+ (Swift 5.9+)
- GRDB.swift 7.0+ / SwiftMath 1.7+ （いずれも自動取得）
- xcodegen 2.40+ （`.app` ビルド時のみ）
- Python 3.10+ （importer 利用時、システム Python / Homebrew / pyenv いずれも可）

## データソース

`~/Library/Application Support/Madini Archive/archive.db` を読みます。存在しなければモックデータにフォールバックします。

## デフォルトの表示名について

初回起動時のユーザー名は `Jenna`、アシスタント名は `Madini` です。これはどちらも作者のハンドルネーム（本名ではない）に由来します。アバター画像も同梱されています。**両方とも Settings（⌘,）→ Identity から自由に変更可能** です — 名前、画像、デフォルトに戻すボタンが揃っています。

## Importer の解決順

ドラッグ＆ドロップ時、Swift app は次の順で `split_chatlog.py` を探します（詳細は `Sources/Services/JSONImporter.swift`）。

1. `MADINI_IMPORTER_DIR` 環境変数（明示指定）
2. `.app` バンドル内の `Contents/Resources/Python/`（配布ビルド）
3. 作業ディレクトリ直下の `Python/`（リポジトリでの `swift run`）
4. `~/Madini_Dev`（旧来の standalone Python チェックアウト、後方互換）

## ディレクトリ構成

```
Sources/
├── MadiniArchiveApp.swift        @main + MainView
├── Core/                         protocol 定義 + AppServices
├── Database/                     GRDB 実装
├── Preferences/                  UserDefaults bound state
├── Services/                     JSONImporter, ImportService
├── ViewModels/                   UI 状態
├── Views/                        SwiftUI View
│   ├── Shared/                   両 OS 共通
│   ├── macOS/                    macOS 専用
│   └── iOS/                      iOS 専用
├── Utilities/                    AppPaths など
└── Resources/                    Asset / バンドルデータ

Python/                           importer core（split_chatlog.py + archive_store.py）

docs/                             investigation note / migration plan
```

## ライセンス

MIT。詳細は [LICENSE](./LICENSE) を参照。
