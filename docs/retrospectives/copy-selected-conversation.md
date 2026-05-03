# 振り返り: 「選択した会話をコピー」機能 (Sub-A + Sub-B)

実施: 2026-05-03
担当: Claude Code (worktree `claude/brave-chatterjee-4a6474`)
発注: ジェンナ
受注フロー: 調査 (`docs/investigations/copy-selected-conversation.md`)
            → Sub-A (Exporter + テスト)
            → Sub-B (UI)
最終 commit: main `a40fcff`

## 何を作ったか

会話一覧 / 会話を展開した時の prompt 一覧で、複数行を Cmd/Shift クリックで
選択し、右クリック → 「選択した会話をコピー」で Markdown 形式の
バンドルをペーストボードに書き込む機能。Phase A のメッセージ正規化
(`MessageBlock.thinking`) を活用し、Claude の thinking ブロックも
`> [thinking]` 引用として出力に含める。

## 結果

- Sub-A: 1 commit、25 テスト pass、main マージ済み
- Sub-B: 7 commits (うち 5 つは "production ではない view" を patch
  していた空振り)、最終的に 2 つの本物の view (`DesignMockThreadListPane`
  と `DesignMockExpandedPromptList`) に着地
- 全機能 main に push 済み

## 時系列の要点

| 段階 | 起きたこと |
|---|---|
| 調査 | 11 個の判断ポイントを `docs/investigations/copy-selected-conversation.md` に整理。「中央 PromptList カラム」が `.viewer` mode の `ViewerModePane` か、`.default` mode の card list か曖昧だったが **Viewer Mode を主と判断** (誤り、後述) |
| Sub-A | 純粋関数 `SelectedConversationMarkdownExporter` + Clipboard helper 実装。25 テスト pass。中身は問題なし |
| Sub-B 第1弾 | `ViewerModePane` (Sources/Views/Shared/) を multi-select 化、ジェンナに動作確認依頼 |
| ジェンナ「動作しない」 | 私: 「Viewer Mode に切り替えて」と説明 |
| ジェンナ「Viewer モードってデフォルトレイアウトじゃないの？」 | ここで認識のずれ判明 — ジェンナの主目的は `.default` mode の会話カード一覧での multi-select |
| Sub-B 第2弾 | `MacOSRootView.UnifiedConversationListView` (default mode card list) を multi-select 化 |
| ジェンナ「変化ない」 | 多選択ロジック修正、`.contextMenu(forSelectionType:)` 切替、List → Button + 自前 selection… 4 commits 続けるも一度も動かない |
| ジェンナ「やっぱりダメだ。根本的に見直して」 | 限界 |
| computer-use で実機操作 | 私が直接画面を見て確認 → クリックしても modifier が認識されない様子 |
| **真の根本原因の発見** | `MadiniArchiveApp.swift:207` を確認: `RootView` は `DesignMockRootView()` を返している。私が触っていた `MacOSRootView` も `ViewerModePane` も、**Production の RootView() は instantiate していなかった** |
| Sub-B 第3弾 | `DesignMockRootView` 内の `DesignMockThreadListPane` (default mode card list) を multi-select 化、commit `3b4f6ad` |
| 動作確認 | computer-use で ⌘/Shift クリック動作 + コンテキストメニュー + コピー結果 326 KB の Markdown を確認 ✓ |
| ジェンナ「やっぱり変化ない」 | え |
| 画面確認 | ジェンナは **expanded prompt list (会話を 2 度クリックで展開した状態)** で操作していた。これは `DesignMockExpandedPromptList` (line 3769、これも別の view) |
| Sub-B 第4弾 | `DesignMockExpandedPromptList` を multi-select 化、commit `1e5f103` |
| 動作確認 | Cmd クリック + 右クリック + コピー、各 prompt + thinking 含む Markdown が pasteboard に入ることを確認 ✓ |
| ジェンナ「できた！」 | 完了 |

## 真の根本原因

**`RootView()` が返すのは `DesignMockRootView()`**。
`MacOSRootView` も shared な `ViewerModePane` も `UnifiedConversationListView`
も production では使われない legacy / dead code。本物の UI はすべて
`DesignMockRootView.swift` (5,000 行超) の中の `DesignMock*` プレフィックスの
view で構成されている。

```swift
// Sources/MadiniArchiveApp.swift:202-211
struct RootView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        #if os(macOS)
        DesignMockRootView()    // ← これが production
        #else
        IOSRootView(services: services)
        #endif
    }
}
```

3 surfaces のうちジェンナの主動線で使われるのは:

| 操作 | 表示 | View 名 |
|---|---|---|
| 起動時 / `.default` mode | 中央=会話カード一覧 | `DesignMockThreadListPane` |
| カードを 2 度クリック | 中央=選択カード下に prompt 一覧が展開 | `DesignMockExpandedPromptList` |
| `.viewer` mode (実際は使われない) | 中央=collapsed | (該当 view 自体無し) |

私は最初 `.viewer` mode 用の `ViewerModePane` (legacy) を本物と誤認した。
ジェンナの「カードを開いてプロンプト一覧を表示した時」は実は
`DesignMockExpandedPromptList` のこと。

## なぜこんなに遠回りしたか

### 1. 命名と実体の乖離 (致命的)

「Default mode 用の view」「Viewer mode 用の view」と命名された shared な
view (`UnifiedConversationListView`、`ViewerModePane`) があるのに、
production はそれらを使わず `DesignMock*` プレフィックスの独自実装を
使っている。**コード上の名前 / コメント / docstring と production の
実態が一致していない**。

これは Phase A の retrospective でも同じ事象を見た。Phase A では
sidebar 統合時に「production sidebar = MacOSRootView の sidebar」と
誤認 → 実は DesignMockRootView の sidebar が production だった。
**今回も Phase A で得た知見が活きなかった**。

### 2. 「動作確認」の遅延

調査 → Sub-A → Sub-B 第1弾 → 動作確認、というウォーターフォール
進行で、最初の動作確認まで 4 commits 経ていた。しかも私はジェンナの
動作確認結果を「私が想定するルート (Viewer Mode 切替経由)」で
解釈しようとしたため、ずれの根本に気づくまでさらに数往復かかった。

**人間の動作確認結果が「動かない」と返ってきた時、UI Tour で実機操作を
最初にすべき**。私が SwiftUI のコードを読み直しても、production が
DesignMockRootView だという事実には辿り着かない。`computer-use` で
画面を直接見ることで、ジェンナがどの surface で何をしているかが
即座に分かった。

### 3. SwiftUI multi-select の罠

`List(selection: Set<String>)` の Cmd/Shift multi-select は、
NavigationSplitView の中央列で動作が不安定 (macOS 14 で確認)。
sidebar 列では native 動作するが、中央列では行が単独選択にしか
ならない。これも実機で見るまで気づかなかった。

最終解決は手書きパターン: Button action 内で
`NSApp.currentEvent?.modifierFlags` を読み、自前で selection set を
更新する。Phase A の `WikiFileTreeView` で同じパターンを使っていた。

## 学び

### A. ジェンナのプロジェクトを触る AI へ

1. **`RootView()` の中身を真っ先に読む。**
   `Sources/MadiniArchiveApp.swift` で `RootView` の `body` が何を
   instantiate しているかが production の View tree のエントリポイント。
   `MacOSRootView` などの命名に騙されない。
   ```swift
   #if os(macOS)
   DesignMockRootView()    // ← 2026-05 時点 production
   #endif
   ```
2. **ジェンナの「Viewer Mode」の認識は内部 enum の `.viewer` とは違う**
   可能性がある。「カードを 2 度クリックして展開した状態」 =
   `DesignMockExpandedPromptList` (default mode の延長線、別 mode ではない)。
   ジェンナが「Viewer」と言ったら一旦聞き返す。
3. **動作確認が「動かない」と返ってきたら、コード読み直しに走る前に
   実機を見る**(computer-use で `request_access` → `screenshot` → 操作)。
   ジェンナの環境 / 操作と私の想定がずれている可能性が常に高い。
4. **DesignMockRootView のサイズは 5000+ 行。** 機能を追加する時は
   既存の DesignMock-prefixed view の中で完結することが多い。
   Sources/Views/Shared/ の汎用 view は production には届かないことが多い。

### B. SwiftUI multi-select 実装パターン

非 sidebar 列 (NavigationSplitView の中央 / 詳細列) で安定して動く
multi-select の自作レシピ:

```swift
@State private var selectedIDs: Set<String> = []
@State private var anchorID: String?

// 各行を Button にして、action 内で modifier を読む
Button {
    let flags = NSApp.currentEvent?.modifierFlags
    let shift = flags?.contains(.shift) ?? false
    let command = flags?.contains(.command) ?? false
    handleTap(id: row.id, shift: shift, command: command)
} label: {
    rowContent(row)
        .background(selectedIDs.contains(row.id)
                    ? Color.accentColor.opacity(0.20)
                    : Color.clear)
}
.buttonStyle(.plain)
.contextMenu {
    Button("...") {
        let ids = selectedIDs.contains(row.id) ? selectedIDs : [row.id]
        // ...
    }
}

private func handleTap(id: String, shift: Bool, command: Bool) {
    if shift {
        let anchor = anchorID ?? id
        let range = idsInRange(anchor: anchor, target: id, in: ordered)
        if command {
            selectedIDs.formUnion(range)
        } else {
            selectedIDs = range
        }
    } else if command {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        anchorID = id
    } else {
        selectedIDs = [id]   // bare click は単独選択
        anchorID = id
    }
}
```

ポイント:
- `.contextMenu(forSelectionType:)` は `List/Table` の selection: binding
  と一緒でないと無意味。自前 selection なら per-row `.contextMenu` 必須。
- bare click 時に `selectedIDs = [id]` (空 set ではなく) しておくと、
  multi-select 中の highlight ロジックが一貫する。
- 「multi-select 中は reader を auto-open しない」ガードは別途必要
  (selection.count == 1 でだけ reader 切替)。

### C. 調査レポートの落とし穴

Sub-A 着手前の調査レポート
(`docs/investigations/copy-selected-conversation.md`) は
- 11 個の判断ポイント
- AGENTS.md 整合性チェック
- Phase 1 (thinking 構造保存) の前提確認

をしっかり書いていた。**それでもジェンナの主動線を読み違えた**。
理由は、調査時にジェンナの「過去のスレッドの一部分を抜粋」という
言い回しを `.viewer` mode の prompt directory (1 つの thread の中の
prompt 一覧) と解釈したから。実際のジェンナの mental model は
「会話一覧でいくつかピックアップ」で、片方は default mode の card list、
もう片方は default mode + expand の prompt list。

**調査段階で「ジェンナの普段の操作経路」を 1 度実機 demo で確認すべきだった。**
計画書の精度より、対象 surface の現実認識のほうが影響が大きい。

## 申し送り

### Phase A の retrospective と統合した教訓

Phase A の `docs/retrospectives/PhaseA-WikiReader.md` でも

> プロダクションの sidebar が DesignMockRootView だった
> 「production = MacOSRootView」と決めつけずに、handoff doc の
> 「既存サイドバーの Wikis 項目」が具体的にどちらを指すか確認すべきだった。

と書いていた。**今回も同じ罠を踏んだ**。
今後タスクを受注したら、最初の 1 アクションとして:

```bash
grep -n "RootView()" Sources/MadiniArchiveApp.swift
```

を必ず実行して、production の最上位 view を確定させる。

### TODO: legacy view 整理

`Sources/Views/macOS/MacOSRootView.swift` と
`Sources/Views/Shared/ViewerModePane.swift` は production 未参照。
今回 Sub-B で legacy 側にも multi-select を実装したが、これらは
no-op safety net。本来は削除すべき dead code。Phase 不明の cleanup
タスクで整理。

### TODO: Sub-C (調査レポート §10)

Default mode の `Table` mode (`.table` cascade) で同じ
multi-select copy が動くかは未確認。`ConversationTableView`
(これは production で使われている、`.table` mode 用) の
`.contextMenu(forSelectionType:)` に項目を足したが、Sub-B 後半で
LibraryViewModel API シグネチャを変更した時に整合性チェックが
未完。Sub-C として動作確認 + 必要なら修正。

### Shift クリックの挙動

`DesignMockExpandedPromptList` の Shift クリック挙動だけ最終確認が
できなかった (computer-use で操作中に座標がずれた可能性)。
ジェンナの実機で範囲選択が期待通り動くかは未検証。動かない場合、
`anchorPromptID` の更新タイミングや `idsInRange` の境界条件を
見直す。

## コミットリスト (main 反映済み)

```
a40fcff Merge Sub-B into main: "Copy selected conversation" multi-select
1e5f103 Wire multi-select + "Copy selected conversation" into expanded prompt list
3b4f6ad Wire multi-select + "Copy selected conversation" into DesignMockRootView
6e02f2a Replace List(selection:) with Button + self-managed selection on default-mode card list
d38008a Don't auto-open the reader during multi-select
d94d915 Switch default-mode card list to selection-typed context menu
989409e Extend Sub-B: "Copy selected conversation" on default-mode card list
41ce6b8 Wire ViewerModePane multi-select + "Copy selected conversation" (Sub-B)
7f7ab95 Merge Sub-A into main: SelectedConversationMarkdownExporter
b3e8b85 Treat empty contentBlocks as nil in the selected-conversation exporter
e4ad96d Add SelectedConversationMarkdownExporter (Sub-A)
d828281 Investigate "Copy selected conversation" feature
```

12 commits、最終的に意味があるのは 4 つ (調査レポート、Sub-A本体、
Sub-A 修正、Sub-B 最終 2 commit `3b4f6ad` + `1e5f103`)。
残り 8 commits は legacy view への空振り修正と一時的な逆走。
履歴としては残す (revert/cherry-pick の単位は分けてある)。

---

## 一行要約

**「`RootView` の `body` を読まずにタスクを始めるな」** ——
これが今回の最大の学び。
