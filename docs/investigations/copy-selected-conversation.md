# Investigation: 「選択した会話をコピー」機能

- **日付**: 2026-05-03
- **スコープ**: 設計調査のみ。コード変更なし、新規ソースファイルなし、テストなし。
- **前提**: Phase 1 (thinking 構造保存) は **2026-05-01 完了済み**
  (`docs/plans/thinking-preservation-2026-04-30.md` の §"実施結果サマリー"、
  Phase 0〜6 全完了)。`messages.content_json` 列 + `Message.contentBlocks` +
  `MessageBlock.thinking` ケースは既に live。
- **関連既存実装**: `MarkdownExporter` / `PlainTextExporter` /
  `LLMPromptClipboard` / `PromptListExporter` (どれも `Sources/Views/Shared/`
  配下、純粋関数 enum)
- **要決定: ジェンナに確認** マーカーを各セクションに散らしてある。

---

## 用語整理

タスク仕様の「中央 PromptList カラム」がコードベース上どの View を指すかは
2 通りの読み方があるため、本レポートでは両方をカバーする:

| 解釈 | 該当 View | 選択単位 | コードの場所 |
|---|---|---|---|
| **A. Viewer Mode** | `ViewerModePane` | 1 つの会話の中の複数 prompt | `Sources/Views/Shared/ViewerModePane.swift` |
| **B. Default / Table Mode** | `ConversationCardListView` (default) / `ConversationTableView` (table) | 複数の会話 (各会話の見出し prompt) | `Sources/Views/macOS/ConversationTableView.swift` ほか |

タスク文 §背景の「過去のスレッドの**一部分**を抜粋」が示す主要ユースケースは
**A**(Viewer Mode のスレッド内 prompt 選択)。ただしジェンナがしばしば
"prompt-centered" な見方をするため、**B** (会話単位の選択コピー) も将来要望
として浮上しやすい。本レポートは A を主、B を副として整理する。

要決定: ジェンナに確認 — まず A だけ実装するか、A + B 同時か。本レポートの推奨は
「A を優先、B は別フェーズで判断」。

---

## 1. 影響範囲の特定

### 1.1 変更対象 (主: A 案)

- `Sources/Views/Shared/ViewerModePane.swift`
  - `LazyVStack` ベース。現状は `tabManager.selectedPromptID: String?`
    による単一選択。複数選択の `Set<String>` 状態を新設する必要がある。
  - 行 79-102: `ForEach(...)` ループ + `ViewerPromptRow` がクリックを
    `tabManager.requestPromptSelection(prompt.id)` に流す構造。ここに
    複数選択ロジックと右クリックメニュー設置が要る。
- `Sources/Views/Shared/ConversationDetailView.swift`
  - 既存の純粋関数 enum (`MarkdownExporter` 等) と並ぶ位置に、新規
    Exporter (仮称 `SelectedConversationMarkdownExporter`) を置くのが
    既存パターンに沿う (詳細は §5)。
  - 行 183-214: `ConversationDetailView.promptOutline(for:)` が user-only の
    番号付きアイテムを生成している。新 Exporter はこれと同じ番号付け規則
    を共有する (label 短縮ではなく原文を出すが、index 計算は同等)。
- `Sources/ViewModels/LibraryViewModel.swift`
  - 行 84: `viewerPromptOutline: [ConversationPromptOutlineItem]` を持つ。
    これと並んで `viewerSelectedPromptIDs: Set<String>` を追加するのが
    自然。ただし複数選択の状態を `LibraryViewModel` に持たせるか
    `ReaderTabManager` に持たせるかは**要決定: ジェンナに確認** (§2)。
- `Sources/Resources/Localizable.xcstrings`
  - 「選択した会話をコピー」/ "Copy selected conversation" の新キー追加。

### 1.2 変更対象 (副: B 案)

- `Sources/Views/macOS/ConversationTableView.swift` 行 130-141:
  既に `Table` の `selection: $selection: Set<String>` + `.contextMenu(forSelectionType:)`
  パターンが動いている。ここに「選択した会話をコピー」メニューを
  足すだけで複数会話コピーは実装できる。
- `Default mode` のカードリスト (Sources/Views/Shared/ConversationCard*.swift 系)
  はそもそも複数選択 UI を持っていない。複数選択を導入するなら
  別途 selection state の追加が必要。本レポートでは扱わない (要件外と
  仮定)。

### 1.3 新規追加するもの

| 種別 | 名前 | 配置 | 役割 |
|---|---|---|---|
| Exporter (純粋関数 enum) | `SelectedConversationMarkdownExporter` | `Sources/Views/Shared/` または `Sources/Services/` (要決定: ジェンナに確認) | `(ConversationDetail, [String /*prompt id*/]) -> String` |
| Clipboard helper | `SelectedConversationClipboard` | 上の Exporter と同ファイル | NSPasteboard / UIPasteboard 書き込み |
| 状態 | `viewerSelectedPromptIDs: Set<String>` | `ReaderTabManager` または `LibraryViewModel` | UI 選択状態 |

新規 Repository メソッドは **不要**。`ConversationRepository.fetchDetail(id:)`
が messages 配列を返すので、選択した prompt id 群と messages を突き合わせれば
「次の prompt までの応答群」をメモリ上で抽出できる。

### 1.4 関連既存型・サービス

- `ConversationDetail` (`Sources/Core/Repositories.swift:142`) — `summary`
  + `[Message]`。messages は user/assistant/system/tool が時系列順に並んだフラット配列。
- `Message` (同 147-181) — `id, role, content, contentBlocks: [MessageBlock]?`。
  Phase 1 完了で contentBlocks は populate されている (1,396 行 = 全体の 2.4%)。
  残りは contentBlocks=nil で、これは "thinking が無かった" or "raw_text を
  失っていて backfill 不可" のいずれか。
- `MessageBlock` (`Sources/Core/MessageBlock.swift`) — enum で
  `.text / .thinking(provider, text, metadata) / .toolUse / .toolResult /
  .artifact / .unsupported`。
- `MessageRenderProfile` (`Sources/Views/Shared/MessageRenderProfile.swift`) —
  per-source の rendering 切替フラグ (`collapsesThinking` 等)。本機能では
  プロフィールに依存させない方針 (§5 で詳述) — Markdown コピーは render
  プロフィールに左右されず "thinking がある全部出す" のが意図。
- `ConversationRepository` プロトコル (`Sources/Core/Repositories.swift:793`)
  — `fetchDetail(id:)` で十分。GRDB 直接アクセスは `GRDBConversationRepository`
  の中に閉じている (UI から触れない)。
- `LLMPromptClipboard` / `PromptListClipboard`
  (`Sources/Views/Shared/ConversationDetailView.swift:1576` および
  `Sources/Views/Shared/PromptListExporter.swift:91`) — 既存の pasteboard
  helper パターン。`@MainActor static func copy(_:)` の定型を踏襲する。

---

## 2. SwiftUI における複数選択の実装パターン

### 2.1 現状認識: ViewerModePane は LazyVStack ベース

`ViewerModePane.swift:73-105` のコア構造:

```swift
ScrollViewReader { proxy in
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(viewModel.viewerPromptOutline.enumerated()),
                    id: \.element.id) { offset, prompt in
                ViewerPromptRow(
                    prompt: prompt,
                    isAlternate: offset.isMultiple(of: 2),
                    isSelected: prompt.id == tabManager.selectedPromptID,
                    onSelect: { ... }
                )
            }
        }
    }
}
```

つまり `List(selection:)` の native multi-select は使えない (List ではない)。
**手動状態管理**が必要。これは意図的な選択で、`ScrollViewReader` ベースの
プログラム的スクロールと alternating-stripe の見た目を実装するため
LazyVStack に倒している。

### 2.2 複数選択の実装パターン候補

3 通り。

#### 案 1. LazyVStack のまま手動で Shift / ⌘ を判定

NSEvent モニタを `NSApp.currentEvent?.modifierFlags` で照会して、行クリック時の
モディファイア状況に応じて selection set を更新。SwiftUI の Button
`primaryAction` ではモディファイアを直接取れないので、`onTapGesture` +
`NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)` で読む。

実装:
```swift
.gesture(TapGesture().modifiers(.shift).onEnded { ... extendRange ... })
.gesture(TapGesture().modifiers(.command).onEnded { ... toggleOne ... })
.onTapGesture { ... single select ... }
```

優先度は specific が先 (modifiers 付き → bare)。

#### 案 2. List(selection:) に置き換える

`List` を使えば `selection: Binding<Set<String>>` でネイティブに複数選択
+ Shift / ⌘ が Apple の標準ハンドラに乗る。ただし alternating stripe は
`.listRowBackground` + 自前判定が要る。`ScrollViewReader.scrollTo` も
List 内で動くが、行を `.id(...)` できる挙動の安定度は OS バージョン
依存。Phase A の WikiFileTreeView でも List → LazyVStack 移行を経験している
(Obsidian-style row click expand)。

#### 案 3. `Table` に置き換える

`ConversationTableView` (B 案の middle pane) は `Table` を使い
`.contextMenu(forSelectionType:)` まで済んでいる。同じパターンを
ViewerModePane にも持ち込む選択肢。ただし Viewer Mode の見た目は dense な
「2 行 label + 番号」なので Table の表組みに馴染みにくい。

#### 推奨

**案 1 (LazyVStack のまま手動管理)** を推奨。理由:
- 既存の見た目・スクロール挙動を保てる
- AppKit/SwiftUI の OS 間挙動差に晒されにくい
- Phase A で同型の手書きを既に WikiFileTreeView で実装済み
  (`Sources/Wiki/Views/WikiFileTreeView.swift`、行クリック展開の自前実装)

**要決定: ジェンナに確認** — 案 1 で進めて OK か、List native へ寄せるか。

### 2.3 selection state の置き場所

候補:
1. `ReaderTabManager` — タブ単位の状態 (現在の `selectedPromptID` と並ぶ)
2. `LibraryViewModel` — library 全体の状態
3. `ViewerModePane` の `@State` — view-local

`ReaderTabManager` が自然。理由: タブを切り替えると selection は破棄したい
(別会話の prompt id とは互換でない)。`tabManager.selectedPromptID` と
ライフサイクルが同じ。

```swift
// ReaderTabManager に追加 (案):
var multiSelectedPromptIDs: Set<String> = []
```

ただし、現在の `selectedPromptID: String?` はリーダーの「今読んでる
prompt」を表すフィールドで、明示的な multi-select state とは意味が違う。
これらを別フィールドにするか、新フィールドが旧を包含するか — 設計判断が
必要。**要決定: ジェンナに確認**。

### 2.4 既存キーボードショートカットとの衝突

調査: `Sources/MadiniArchiveApp.swift` の AppCommands には:
- ⌘W (Close)
- ⌘= / ⌘- / ⌘0 (Body text size)
- ⌘O (Open Drop Folder)
- ⌘⌫ (Delete Snapshot)
- ⌘F (Find)
- ⇧⌘W (Open Wiki Browser、Phase A で追加)

「選択した会話をコピー」は基本マウス右クリック起動で衝突しない。
キーボードショートカットを足すなら ⌘C は OS 標準のコピーと衝突するので避ける。
⇧⌘C なら macOS 全体で空いている (Mail.app の Show Bcc ぐらい)。
ただし範囲外。**要決定: ジェンナに確認**(必要なら別タスクで)。

---

## 3. コンテキストメニューの実装

### 3.1 SwiftUI `.contextMenu` の選択範囲対応

SwiftUI には 2 種類のコンテキストメニュー API:

1. `.contextMenu { ... }` — 単一 view に紐付く。複数選択を渡せない。
2. `.contextMenu(forSelectionType: T.self) { ids in ... }` — `Table` /
   `List(selection:)` に紐付き、選択中の id 集合をクロージャに渡す。

LazyVStack には **2 が使えない**(List/Table 専用)。1 を各行に付けると、
右クリックされた行だけが選択中であってもメニューは出るが、複数選択
状態を考慮するには selection set を view 側で参照しないといけない。

### 3.2 既存の複数選択コンテキストメニュー

唯一の前例は `ConversationTableView.swift:130`:

```swift
.contextMenu(forSelectionType: String.self) { ids in
    if let id = ids.first {
        Button("Open") { openConversation(id: id) }
    }
} primaryAction: { ids in
    if let id = ids.first { openConversation(id: id) }
}
```

これは Table 専用 API。ViewerModePane の LazyVStack には適用不可。

### 3.3 LazyVStack + 複数選択コンテキストメニューの実装方針

行ごとに `.contextMenu { ... }` を付け、メニュー内で
`if !tabManager.multiSelectedPromptIDs.contains(prompt.id) { /* 単一処理 */ }
else { /* 複数処理 */ }` のように selection set を観て切替える。

```swift
ViewerPromptRow(prompt: prompt, ...)
    .contextMenu {
        Button("選択した会話をコピー") {
            let ids = tabManager.multiSelectedPromptIDs.contains(prompt.id)
                ? tabManager.multiSelectedPromptIDs
                : [prompt.id]
            handleCopy(ids: ids)
        }
        .disabled(tabManager.multiSelectedPromptIDs.isEmpty
                  && /* 単独選択も無い場合は disable */)
    }
```

「右クリックされた行が selection set に含まれているなら set を、
そうでなければその 1 行だけを」というのが macOS Finder の標準挙動。
既存 ConversationTableView は Table のため Apple が裏でこれを処理している。
LazyVStack では明示的に書く必要がある。

### 3.4 NSMenu の必要性

NSMenu (AppKit) ベースに落とす必要は **無い**。SwiftUI `.contextMenu`
で十分。NSMenu に落とすメリットは「動的に enabled/disabled を細かく
変える」「キーボードショートカットを per-item で出す」あたりだが、本機能は
1 項目・選択数が 0 でなければ enable で済むので SwiftUI 側だけで完結する。

---

## 4. データ取得とドメインモデル

### 4.1 取得すべきデータ

ユーザー操作: 「viewer mode の prompt directory で `[1, 3, 7]` を選択 →
コピー」。

必要なデータ:
- 各選択 prompt (= user role の Message) 本体
- 各選択 prompt の **直後** から **次の user message の直前** までの
  全 assistant / tool / system message
- 末尾の prompt が選ばれた場合は thread 末尾まで

これらはすべて `ConversationDetail.messages: [Message]` から index 走査で
切り出せる。新規 SQL クエリは不要。

### 4.2 既存 API との整合

`ConversationRepository.fetchDetail(id:)` が ConversationDetail を返す。
ViewerModePane は既に `LibraryViewModel.viewerDetail` でこれをキャッシュ
しているので、コピー時点で既に detail はメモリ上にある。
追加 fetch は **発生しない**。

```swift
// pseudo
let detail = libraryViewModel.viewerDetail!
let segments = SelectedConversationMarkdownExporter
    .extract(detail: detail, selectedPromptIDs: ids)
let markdown = SelectedConversationMarkdownExporter.render(segments)
```

### 4.3 segment 抽出ロジック (擬似コード)

```swift
struct PromptSegment {
    let promptIndex: Int   // user-only 1-based index (既存 promptOutline と整合)
    let prompt: Message
    let responses: [Message]  // assistant/tool/system, in order
}

static func extract(
    detail: ConversationDetail,
    selectedPromptIDs: Set<String>
) -> [PromptSegment] {
    var segments: [PromptSegment] = []
    var pending: PromptSegment?
    var userIndex = 0

    for msg in detail.messages {
        if msg.isUser {
            if let p = pending { segments.append(p) }
            userIndex += 1
            pending = selectedPromptIDs.contains(msg.id)
                ? PromptSegment(promptIndex: userIndex,
                                prompt: msg, responses: [])
                : nil
        } else if var p = pending {
            p.responses.append(msg)
            pending = p
        }
    }
    if let p = pending { segments.append(p) }
    return segments
}
```

非連続選択 `[1, 3, 7]` は segments 配列に index 1, 3, 7 だけが残るので、
出力 Markdown 上で「## 1. ...」「## 3. ...」「## 7. ...」と自然に番号が
飛ぶ (タスク仕様 §"連番の扱い" と整合)。

### 4.4 ページネーション必須ルールとの関係

AGENTS.md「Scale Resistance」の「All list queries must accept offset/limit」
とは **抵触しない**。
本機能は既に取得済みの `ConversationDetail.messages` をメモリ上で走査する
だけで、新規 list クエリは発行しない。`fetchDetail` 自体も「特定 conversation
の全 messages を取る」という意味で全件取得だが、これは AGENTS.md でも
許容されている用法 (詳細表示には必要)。

ただしメモリ上限の懸念は別途 §7.6 で扱う。

### 4.5 thinking ブロックの取り出し

Phase 1 完了済みのスキーマ:
- `messages.content_json` 列 (Phase 1 で追加)
- 1,396 行に thinking blocks が backfill 済み (Phase 5 の結果)
- Swift 側: `Message.contentBlocks: [MessageBlock]?` で読める (Phase 3)

新 Exporter での扱い:
```swift
for case .thinking(let provider, let text, _) in (assistantMsg.contentBlocks ?? []) {
    output.append("> [thinking]")
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        output.append("> \(line)")
    }
    output.append("")
}
```

`contentBlocks == nil` のメッセージ (= 古い row、または thinking がない通常応答)
では thinking セクションは出力しない (タスク仕様 §"thinking 表現" の
"thinking が無いアシスタント応答の扱い" = §7.3 と整合)。

ChatGPT o3 系の reasoning も `MessageBlock.thinking(provider: "openai-o3", ...)`
として同じケースに乗っている (Phase 2b)。Markdown 上は同じ
`> [thinking]` ラベルで OK。Exporter 側で provider 別に文言を変える需要は
今のところ無い。**要決定: ジェンナに確認** — `[thinking]` 固定で良いか、
provider に応じて `[thinking-claude]` / `[reasoning-o3]` 等に分けるか。

---

## 5. Markdown 出力の組み立て

### 5.1 配置場所

タスク仕様は「Interpretation 層に新規 Exporter」と書いているが、
AGENTS.md の 5 層には「Interpretation 層」という名は無く、
**Raw / Normalize / View / Cache / UI** の 5 層構成。タスクの "Interpretation"
は概念上 "Normalize した Models から人間可読フォーマットを生成する純粋関数群"
を指している。

既存実装の現実: `MarkdownExporter`, `PlainTextExporter`,
`LLMPromptClipboard` は `Sources/Views/Shared/ConversationDetailView.swift`
内の `enum`。`PromptListExporter` (Phase 直近で追加) は独立ファイル
`Sources/Views/Shared/PromptListExporter.swift`。

これらは厳密には「UI 層に同居している純粋関数」であり、AGENTS.md 5 層分離の
"Normalize / Cache" 層には属さない。SwiftPM の単一 target 構造ゆえ層を
namespace で切り分けてはいない。

新 `SelectedConversationMarkdownExporter` も同じパターンに乗せる:

- 配置: `Sources/Views/Shared/SelectedConversationMarkdownExporter.swift`
  (PromptListExporter と同じ場所、独立ファイル)
- 形態: `enum` (純粋関数の集合、副作用なし、`@MainActor` 不要)
- 入力: `(ConversationDetail, Set<String>)` または `[PromptSegment]`
- 出力: `String` (Markdown UTF-8)

副作用 (NSPasteboard 書き込み) は併設の `enum SelectedConversationClipboard`
に切り分ける (`LLMPromptClipboard` / `PromptListClipboard` と同じ
書き分けパターン)。

**要決定: ジェンナに確認** — `Sources/Services/` に置く案もある
(ジェンナの "Interpretation 層" がそちらをイメージしている可能性)。
私の推奨は既存の `Sources/Views/Shared/` で並べる方。

### 5.2 純粋関数として設計可能か

YES。`ConversationDetail` を入力にして `String` を返すだけで、副作用なし、
`@MainActor` 不要、テスト容易。`PromptListExporter` がまさにこのパターンで、
`Tests/MadiniArchiveTests/PromptListExporterTests.swift` に 16 ケースの
fixture テストが乗っている。同じパターンを踏襲できる。

### 5.3 既存 Renderer / Profile との責務分離

`MessageBubbleView` は `MessageRenderProfile` を見て thinking を fold する/
しないを切り替える。コピー出力は **Profile に依存させない** 設計を推奨:
- コピーは「全部見せる」のが目的 (folder/expander UI が無い)
- Profile は表示時の表示密度を調整する役割
- コピー時に profile 由来の fold 判定が走ると、ユーザーが期待する
  「contents 全部入り」と乖離する

§4.5 の擬似コードはこれに沿っている (profile を見ずに contentBlocks だけ
を参照)。

### 5.4 出力フォーマットの仕様化

タスク仕様の formatted 例:

```markdown
# {スレッドタイトル}

- Date: {YYYY-MM-DD}
- Model: {Claude / GPT-4o / Gemini など}
- Source: Madini Archive

---

## {プロンプト連番}. {プロンプト冒頭の短縮表示}

**{ユーザー名}:**
{プロンプト本文}

**{アシスタント名}:**

> [thinking]
> {thinking 本文}

{応答本文}

---
```

判断ポイント:

- **ユーザー名 / アシスタント名**: タスク仕様には「{ユーザー名}」と書かれて
  いるが、archive.db には個人名が入っていない。`ConversationDetail.summary.source`
  が "claude" / "chatgpt" / "gemini" のいずれかなので、それを capitalize して
  "Claude" / "ChatGPT" / "Gemini" を assistant 表記にし、user 側は固定で
  "User" にするのが妥当。**要決定: ジェンナに確認** — "User" 固定で OK か、
  `IdentityPreferencesStore` の表示名を引っ張ってくるか
  (Phase A 時点では `Sources/Preferences/IdentityPreferencesStore.swift` に
  `Jenna` / `Madini` などのカスタム名が保存される設計あり)。
- **Date format**: `summary.primaryTime` は文字列保存
  (`"2026-04-28 10:28:20"`)。`YYYY-MM-DD` への切り出しは prefix 10 文字で
  足りる。タイムゾーンは保存時のものをそのまま (再フォーマットしない)。
- **プロンプト冒頭の短縮表示**: 既存 `ConversationDetailView.promptLabel(from:)`
  (行 224-240) が 72 文字制限 + 全空白圧縮 + `…` で生成している。これを
  そのまま再利用するか、Exporter 側で別ルールにするかは判断要。私の推奨は
  既存ヘルパーを再利用 (整合性確保)。**要決定: ジェンナに確認**。
- **`---` 区切り**: 各 prompt segment の前後に置く案。最初と最後の二重
  `---` は重複するので除く。
- **thinking が複数ある場合**: 1 message 内に複数の `.thinking` block が
  ありうる (Claude の長考)。順序を保って各々を独立した `> [thinking]`
  ブロックとして出す。間に通常 `.text` block があるなら text → thinking →
  text の順で交互に出す (タスク仕様 §"thinking 表現" の "複数行 thinking
  は各行 `>` プレフィックス" と整合、複数 thinking ブロックの並びは
  暗黙的に「順序保持」)。

### 5.5 非テキストブロックの扱い

`MessageBlock` には `.toolUse / .toolResult / .artifact / .unsupported`
もある。コピー出力では:

- `.toolUse(name, inputSummary)` → `> [tool: {name}]` + `> {inputSummary}`
  あたりが妥当
- `.toolResult(name, isError, summary)` → 同様、エラー時は `[tool error: {name}]`
- `.artifact(identifier, title, kind, content)` → タイトル + コードブロック
  (kind を language hint に使う)
- `.unsupported(rawType)` → コメントで `<!-- unsupported block: {rawType} -->`

これらは **Phase A スコープ外** だが、Exporter の擬似コードでは
exhaustive switch にして将来追加の入り口を作っておくのが良い。
**要決定: ジェンナに確認** — Phase 1 (本機能) で .text / .thinking のみ
対応 + その他は plain content (= `Message.content` フィールドの flat 文字列)
にフォールバックするか、最初から全ブロック対応するか。私の推奨は前者
(段階リリース)。

---

## 6. NSPasteboard への書き込み

### 6.1 既存パターン

`LLMPromptClipboard.copy(_:)` (`Sources/Views/Shared/ConversationDetailView.swift:1576-1588`):

```swift
@MainActor
static func copy(_ detail: ConversationDetail) {
    let text = PlainTextExporter.export(detail)
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = text
    #endif
}
```

これに倣う。

### 6.2 リッチテキスト併載 (`public.rtf` + `public.utf8-plain-text`)

調査結果:

- ChatGPT / Claude.ai / Gemini の貼り付け先 (web チャット box) はだいたい
  プレーンテキスト優先で受ける。Markdown 記法はそのまま文字列として渡る。
- macOS Notes、TextEdit (rich mode)、Bear、Obsidian は RTF や HTML を
  優先的に拾うので、もし RTF を併載するとそこでは Markdown が消えて
  rendered text になる (`#` が消えて見出しに、`>` が消えて引用ボックスに、
  など)。これは Markdown を残したい本機能の意図に**反する**。
- 結論: **plain text のみ**で OK。`pasteboard.setString(text, forType: .string)`
  だけで十分。RTF 併載はしない。

### 6.3 Claude.ai での解釈

調査結果 (実機テストはせず、Anthropic の公開仕様に基づく推定):

- Claude.ai の貼り付けボックスは Markdown を解釈してリッチプレビューに
  変換する仕様あり (公式 docs)。`#` 見出し、`>` 引用、コードブロックは
  正しく解釈される。
- `> [thinking]` は引用ブロックの 1 行目として処理されるが、Claude 側で
  「thinking」が特殊解釈されるわけではない。普通の引用として読まれる。
  これはタスク仕様の意図と合致 (人間が読む context として渡したい)。

### 6.4 文字エンコーディング

`String → NSPasteboard.setString(_:forType:.string)` は UTF-16 で内部処理、
読み出し時に UTF-8 でエクスポートされる。日本語、絵文字、結合文字は
すべて維持される。問題なし。

---

## 7. エッジケース一覧

### 7.1 選択 0 件のとき

メニュー項目を `.disabled(true)` にする。非表示 (`if isEnabled { Button(...) }`)
よりも `.disabled` の方が「機能が存在することを示しつつ今は使えない」
というアフォーダンスが残るので推奨。

### 7.2 選択 1 件のときの挙動

普通にコピー。タスク仕様もこれを許容。番号は単独で `## 1.` (ユーザー
prompt が thread 内で 1 番目だった場合) または `## 5.` (5 番目だった場合)
で出る。

### 7.3 thinking が無いアシスタント応答

`Message.contentBlocks` が nil または `.thinking` を含まない場合、thinking
セクションを **出力しない**(空の `> [thinking]` を出さない)。タスク仕様
§"thinking 表現" の "thinking が無いアシスタント応答の扱い (セクション全体を
出さない)" と整合。

### 7.4 非テキストブロック

§5.5 で扱った。Phase 1 では plain content フォールバック推奨。

### 7.5 失敗時のエラーハンドリング

| 失敗 | 対処 |
|---|---|
| ConversationDetail がまだロードされていない | メニューを disable (selection が無いはずなので 7.1 と同じ枝) |
| Pasteboard 書き込み失敗 | `setString` は Bool を返さない (void)。失敗検出は `pasteboard.writeObjects([NSString])` で Bool が取れるが既存パターンは setString。Phase 1 では検出しない (失敗事例は実質ゼロ) |
| 選択 prompt id が detail.messages に見つからない | extract で空 segment を返す → Markdown は header だけになる。空チェックで「No content to copy」を pasteboard にせず黙って no-op が安全。**要決定: ジェンナに確認** |

### 7.6 メモリ上限の見積もり

`ConversationDetail.messages` を全件メモリに乗せる前提:

- 平均 message: 1 KB (日本語混在の通常応答)
- 大きい thread: 200 messages × 5 KB = 1 MB
- Markdown 化後のテキスト: thinking blocks 含めて 5x 程度 → 5 MB
- Pasteboard 1 件 = ~5 MB は実用範囲内 (NSPasteboard は数十 MB まで動く)

選択件数の上限:
- 1 thread 内で全 prompt 選択 (~200 件) → 5 MB → OK
- 複数 thread (B 案、500 件選択) → 100 MB → 危険

A 案 (1 thread 内) では実質的な上限なし、B 案では選択上限 (例: 50 件) を
設けるべき。**要決定: ジェンナに確認** — A 案だけなら考慮不要。

---

## 8. Phase 1 への影響

タスク仕様は Phase 1 に追加要件があるかを問うているが、
**Phase 1 は 2026-05-01 完了済み** (`docs/plans/thinking-preservation-2026-04-30.md`
の §"実施結果サマリー"、Phase 0〜6 全完了)。本機能の要求から逆算した
Phase 1 への追加要件は **存在しない**(以下、確認結果)。

### 8.1 thinking ブロックの順序

Phase 1 のスキーマ (`messages.content_json`) は配列で順序を保持。
`MessageBlock` は配列のまま `Message.contentBlocks: [MessageBlock]?` に乗る。
**順序保持済み** ✅

### 8.2 1 message に複数 thinking

`[MessageBlock]` 配列で表現可能。Phase 5 の backfill 結果でも実例あり
(Claude の長考 1 ターンで thinking → text → thinking → text)。**対応済み** ✅

### 8.3 取り出しコスト

クエリは既存 `fetchDetail(id:)` のみで、O(N) で messages を返す
(N = 1 conversation 内の messages 数)。Index は不要。
**O(N) に収まる** ✅

### 8.4 結論

Phase 1 への追加要件: **なし**。Phase 1 のスキーマと Swift 読み込み
(`Message.contentBlocks`) は本機能をフル サポートしている。

---

## 9. AGENTS.md との整合性チェック

### 9.1 レイヤー分離 (5 層)

新 Exporter は「Models 入力 → String 出力」の純粋関数なので、
AGENTS.md の 5 層 (Raw / Normalize / View / Cache / UI) のうち
**View / UI 層に同居する純粋関数**として扱う。GRDB を直接触らない、
SQL を書かない、`@EnvironmentObject` を持たない。違反なし。

### 9.2 Repository protocol 越しのアクセス

新規 Repository メソッドは追加しない (§4.2)。既存の
`ConversationRepository.fetchDetail(id:)` をそのまま使う。違反なし。

### 9.3 ページネーション必須

list クエリを発行しない (§4.4)。違反なし。

### 9.4 「AI 応答の品質指標化」アンチパターン

該当しない。本機能は AI の出力をそのまま提示するだけで、品質スコアや
ランキングを生成しない。

### 9.5 「原文保持」原則

タスク仕様には書かれていないが、AGENTS.md「Original Preservation」§"If rendering
interprets Markdown, math, or HTML, prefer designs that can still return to a
raw/plain view." に照らすと、**コピー出力は "rendering" の一種** と読める。
コピー結果から raw source への導線は本来必要だが、
- 本機能は **Markdown フォーマットそのもの** を出力するので、すでに raw に
  近い (Markdown は plain text に解釈なしで戻れる)
- thinking block は raw text を `>` 引用にしただけで内容は保持
- vault への raw_text 参照 ID 等の埋め込みは Phase 1 (本機能) では過剰

判断: **導線は不要**。出力 Markdown 自体が raw 等価。**要決定: ジェンナに
確認** — 後続フェーズで「コピー出力の脚注に conv_id を埋める」
オプションを追加する余地は残しておく。

### 9.6 Privacy / Personal Data

ジェンナがコピー出力を別の Claude セッションに貼ることが想定用途。
このとき会話本文に個人情報 (家族名、職場名、etc) が含まれる場合がある。
これは「ユーザーが自分のデータを自分で扱う」操作なので、AGENTS.md の
"Coding AI session" 制約 (= AI に実データを扱わせない) には抵触しない。
ただしジェンナがコピー結果をスクショや課題報告に貼る際は通常通りの
注意 (synthetic に書き換える) が必要 — これは README / SECURITY.md で
既に書かれているのでドキュメント追加は不要。

---

## 10. 推奨実装順序とリスク

実装フェーズを **3 つのサブタスク**に分割する。

### Sub-A. Exporter + テスト (最小、独立)

**達成条件**:
- `Sources/Views/Shared/SelectedConversationMarkdownExporter.swift` 新規追加
  (enum + 純粋関数)
- `Sources/Views/Shared/SelectedConversationClipboard.swift` (またはペアの
  enum を同じファイルに収める) 新規追加
- `Tests/MadiniArchiveTests/SelectedConversationMarkdownExporterTests.swift`
  新規追加 — header / segment 抽出 / thinking blocks / 連続選択 /
  非連続選択 / 末尾 prompt / thinking なし / 空選択 をカバー
- 既存テスト 100% 通過

**ロールバック単位**: 1 commit。完全に独立した新規ファイル群なので
revert が単純。

**依存**: なし (Phase 1 は完了済み)。

### Sub-B. Viewer Mode の複数選択 + コンテキストメニュー

**達成条件**:
- `ReaderTabManager` に `multiSelectedPromptIDs: Set<String>` 追加
- `ViewerModePane` の `ViewerPromptRow` を Shift / ⌘ クリック対応に拡張
- `.contextMenu` 追加、選択件数によって enabled / disabled 切替
- Localizable.xcstrings に「選択した会話をコピー」キー追加
- 手動 QA: 単独選択コピー、Shift 範囲選択、⌘ 個別選択、選択 0 件で disable

**ロールバック単位**: 1 commit。Sub-A の Exporter を呼び出すだけなので、
ここを revert すると UI が単独選択に戻るだけ。Exporter は残る (他から
呼ばれていなければ dead code、呼ばれていれば動く)。

**依存**: Sub-A の Exporter シグネチャが先に確定している必要あり。
内容は並行作業可。

### Sub-C. (任意) Default Mode の `Table` selection 経由のコピー

**達成条件**:
- `ConversationTableView.swift` の `.contextMenu(forSelectionType:)` に
  「選択した会話をコピー」項目追加
- 各選択 conversation について `fetchDetail` を順次呼び (上限 50 件など
  の cap)、Markdown を結合
- 進捗 UI (ProgressView) と cancel 対応

**ロールバック単位**: 1 commit。

**依存**: Sub-A の Exporter 拡張 (複数 conversation の Markdown 結合
規則を Exporter 側でサポートする必要あり)。

**スコープ判断**: ジェンナの主要ユースケース (1 thread 内 prompt 抽出) には
不要。**要決定: ジェンナに確認** — Phase 1 で Sub-C も含めるか、別フェーズに
切り出すか。私の推奨は別フェーズ。

### 10.1 リスク

| リスク | 確率 | 影響 | 緩和策 |
|---|---|---|---|
| LazyVStack の Shift / ⌘ ハンドラが OS バージョン差で挙動分岐 | 中 | 中 (UX 不安定) | Phase A の WikiFileTreeView 流の手書きで OS 差を最小化、QA 必須 |
| `ReaderTabManager` の selection state を multiSelected に拡張すると既存の単独選択 (現在の reader scroll 同期) が壊れる | 中 | 高 (回帰) | `selectedPromptID` (reader 同期用) と `multiSelectedPromptIDs` (UI 操作用) を別フィールドに分離 |
| Exporter の thinking 出力で provider 別に表記が割れる要望が後出し | 低 | 低 (微修正) | enum 化しておけば追加対応が容易 |
| 非連続選択時の番号飛びが UX として違和感 | 低 | 低 | タスク仕様で「連番自体が抜けの存在を伝える」と明示済み、QA で確認 |
| `ConversationDetail` を巨大 thread (~1000 messages) で fetch するときの初期描画遅延 | 低 | 中 | 既存挙動 (ViewerModePane は既にこれをやっている)、本機能で悪化はない |

### 10.2 推奨着手順

1. Sub-A 着手、テスト full pass まで
2. Sub-A 完了 commit / レビュー
3. Sub-B 着手 (Sub-A の Exporter API を呼ぶ)
4. Sub-B 手動 QA
5. (判断) Sub-C を Phase 1 で続行 or 別フェーズへ繰り越し

総工数感: Sub-A 半セッション、Sub-B 半セッション、Sub-C (実装するなら)
半セッション。

---

## 要決定: ジェンナへの確認事項まとめ

本レポート中に散らした 11 個を一覧化:

1. (用語整理) A 案 (1 thread 内 prompt 選択) のみ実装か、A + B (会話単位
   選択) 同時か。
2. (§2.2) 複数選択は LazyVStack で手動管理 (案 1) で進めて OK か。
3. (§2.3) selection state は `ReaderTabManager` に置く (`selectedPromptID`
   と並ぶ独立フィールド) で OK か。
4. (§2.4) ⇧⌘C などキーボードショートカット追加は本機能スコープ外で OK か。
5. (§4.5) thinking 表記は `[thinking]` 固定で OK か、provider 別に
   `[thinking-claude]` / `[reasoning-o3]` 等にするか。
6. (§5.1) 新 Exporter の配置は `Sources/Views/Shared/` (PromptListExporter
   と並ぶ) で OK か、`Sources/Services/` を希望するか。
7. (§5.4) ユーザー名表記は固定で "User" / アシスタント名は source 由来の
   capitalize ("Claude", "ChatGPT", "Gemini") で OK か、IdentityPreferences
   と連動させたいか。
8. (§5.4) プロンプト冒頭短縮は既存の `promptLabel(from:)` (72 文字 + `…`) を
   再利用で OK か。
9. (§5.5) Phase 1 (本機能) は .text / .thinking のみ対応で .toolUse 等は
   plain content フォールバックで OK か、最初から全ブロック対応か。
10. (§7.5) 選択 prompt id が detail に無い場合、no-op で OK か、空 Markdown
    でもクリップボードに上書きするか。
11. (§9.5) コピー出力に conv_id 等の raw 参照 ID を埋め込む必要があるか
    (Phase 1 では不要と推奨)。

---

## 付録: 既存 Exporter / Clipboard との位置関係

```
Sources/Views/Shared/
├── ConversationDetailView.swift
│   ├── enum MarkdownExporter           ← thread 全体 → .md ファイル / pasteboard
│   ├── enum PlainTextExporter          ← thread 全体 → .txt ファイル / pasteboard
│   ├── enum LLMPromptClipboard         ← PlainTextExporter を pasteboard へ ("コピー" 項目)
│   └── static promptOutline / promptLabel  ← user-only 番号付きヘルパー
├── PromptListExporter.swift
│   ├── enum PromptListExporter         ← thread 全体の prompts のみ → markdown 番号付きリスト
│   └── enum PromptListClipboard        ← 上を pasteboard へ ("プロンプトのみコピー" 項目)
└── (新規) SelectedConversationMarkdownExporter.swift
    ├── enum SelectedConversationMarkdownExporter  ← 選択 prompt + 応答群 → markdown
    └── enum SelectedConversationClipboard         ← 上を pasteboard へ ("選択した会話をコピー")
```

3 つの Exporter は入力範囲と出力形態が違うだけで API パターン
(`enum` の `static func export(...) -> String` + 別 enum の
`@MainActor static func copy(...)`) は完全に揃う。

---

以上。
