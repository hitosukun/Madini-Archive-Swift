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

```sh
swift build
open .build/debug/MadiniArchive
```

### Xcode

1. Xcode で `Package.swift` を開く (File → Open)
2. Scheme を `MadiniArchive` に設定
3. Run (Cmd+R)

Xcode で開くと SwiftUI Preview (`#Preview`) も利用可能。

### 動作要件

- macOS 14 Sonoma+
- Swift 5.9+ / Xcode 15+
- GRDB.swift 7.0+ (Package.swift で自動取得)

## データソース

`~/Library/Application Support/Madini Archive/archive.db` を Python 版と共有。Python 版で作成された DB をそのまま読み取れる。
