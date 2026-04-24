# Madini Archive — SwiftUI Frontend

macOS 向けの read-only archive viewer。既存の Python 版 Madini Archive が canonical な実装であり、この SwiftUI 版はその上に載るフロントエンドとして設計されている。

## この実装の責務

- Presentation: 会話一覧・詳細の表示
- Navigation: sidebar / detail の Finder ライクな操作
- UI State: 選択、フィルタ入力、表示モードなど一時的な状態

## やらないこと

- Import / search / bookmark / virtual thread の本質的な業務ロジックの再実装
- SQLite schema に強く依存した画面実装の拡大
- Python core の機能の完全な再現
- iOS 対応の作り込み

## 将来の接続先

`~/Library/Application Support/Madini Archive/archive.db` が存在すれば GRDB 経由で読み取り専用で接続する。なければモックデータにフォールバック。

将来的に以下に差し替え可能:

- Python core が提供する JSON API / IPC
- Service layer protocol の別実装

接続方法が変わっても、`ConversationRepository` protocol の実装を差し替えるだけで View / ViewModel は影響を受けない。

## ディレクトリ構成

```
Sources/
├── MadiniArchiveApp.swift      @main + MainView
├── Models/                     DTO (GRDB 非依存)
├── Repositories/
│   ├── Protocols/              UI が依存するインターフェース
│   ├── GRDB/                   archive.db 読み取り実装
│   └── Mock/                   開発・Preview 用モック
├── Services/                   依存コンテナ (AppServices)
├── ViewModels/                 UI 状態管理
├── Views/                      SwiftUI View コンポーネント
├── Utilities/                  汎用ヘルパー (AppPaths)
└── Fixtures/                   Preview 用サンプルデータ
```

## 設計原則

- **UI は protocol にだけ依存する** — View / ViewModel は `ConversationRepository` protocol を通じてのみデータにアクセスする
- **canonical data は外に置く** — SwiftUI 側にデータの真実を持たせない
- **canonical / derived / UI state を混ぜない** — Model は DTO、ViewModel は UI state、View は presentation に専念
- **DB は readonly で開く** — SwiftUI 側からの書き込みは行わない

## ビルドと実行

### CLI (Swift Package Manager)

日常の開発・テスト用。

```sh
swift build
swift test
open .build/debug/MadiniArchive
```

### Xcode (SPM を開く)

1. Xcode で `Package.swift` を開く (File → Open)
2. Scheme を `MadiniArchive` に設定
3. Run (Cmd+R)

Xcode で開くと SwiftUI Preview (`#Preview`) も利用可能。

### 配布用 `.app` をビルドする

`xcodegen` で `project.yml` から `Madini Archive.xcodeproj` を生成し、
`xcodebuild` で Release ビルドする。 `.xcodeproj` は git 管理外。
`project.yml` を変更した時だけ再生成すれば OK。

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

SPM と Xcode で同じソースツリー (`Sources/`) を共有する。依存
バージョンは `Package.swift` と `project.yml` の両方に書かれているので、
どちらか片方を更新したら必ず両方を揃える。

### 動作要件

- macOS 14 Sonoma+
- Xcode 15+ (Swift 5.9+)
- GRDB.swift 7.0+ / SwiftMath 1.7+ (どちらも自動取得)
- xcodegen 2.40+ (`.app` ビルド時のみ)

## データソース

`~/Library/Application Support/Madini Archive/archive.db` を Python 版と共有。Python 版で作成された DB をそのまま読み取れる。
