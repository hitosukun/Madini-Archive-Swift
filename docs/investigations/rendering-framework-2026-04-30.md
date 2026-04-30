# 調査レポート: ソース × モデル別レンダリング設定フレームワーク

- **日付**: 2026-04-30
- **ブランチ**: `claude/investigate-rendering-framework` (base: main `92bf6d9`)
- **スコープ**: 調査と設計提案のみ（コード変更なし）

---

## 1. 仕様の意図と長期構想

### 1.1 既存機能の意図

Madini Archive には claude ソース固有の表示機能として、Claude の応答中の「内的独白セクション」を折りたたみ可能なブロックに変換し、翻訳ボタンを付与する機能が実装されている。

仕様の本来の意図:

- Claude が user に直接語りかける前後に存在する英語の思考プロセス（"The user wants me to act as..." "Let me think about how to approach..." 等）を折りたたむ
- user（ジェンナ）が読み飛ばせるよう、折りたたみブロックにまとめる
- 大半が英語なので、翻訳ボタンを併設してアクセシビリティを向上
- ブロックヘッダには検出された言語名（例: "English"）を表示

### 1.2 長期構想

Claude / ChatGPT / Gemini / 今後登場するモデルで各社が独自機能を追加していく流れに対し、Madini Archive は long-term archive として以下に柔軟対応できる必要がある:

- Claude の thinking / extended thinking ブロック
- ChatGPT の reasoning trace、tool use、Code Interpreter 出力
- Gemini の grounding citations、web search 結果
- 各社共通の artifact / canvas / 添付ファイル
- 将来登場する未知の構造化要素

monologue 判定の改善を機に、ソース × モデル別にレンダリング挙動を切り替えられる汎用フレームワークを設計し、monologue ブロック化はその最初の利用例として位置付け直す。

---

## 2. 過去の実装痕跡の発掘結果

### 2.1 MessageRenderProfile の発見（最重要）

**commit `09b321c`** ("Pick render behavior per conversation source") で、per-source レンダリングポリシーの仕組みが実装されている。

| 項目 | 内容 |
|------|------|
| ファイル | `Sources/Views/Shared/MessageRenderProfile.swift` (65行) |
| ブランチ | `vault/phase-c-importer-audit` およびその子孫 (phase4〜phase9) |
| main マージ状況 | **未マージ** (main HEAD `92bf6d9` には存在しない) |
| 導入日 | 2026-04-24 |

**コード全文**:

```swift
struct MessageRenderProfile: Hashable, Sendable {
    var collapsesForeignLanguageRuns: Bool

    static let passthrough = MessageRenderProfile(
        collapsesForeignLanguageRuns: false
    )

    static let claude = MessageRenderProfile(
        collapsesForeignLanguageRuns: true
    )

    static func resolve(source: String?, model: String? = nil) -> MessageRenderProfile {
        guard let normalized = source?.lowercased(), !normalized.isEmpty else {
            return .passthrough
        }
        switch normalized {
        case "claude":
            return .claude
        default:
            return .passthrough
        }
    }
}
```

**設計意図**（コメントより抜粋）:

> "Why a profile struct, not `if source == "claude"` scattered through the view: Madini ingests from ChatGPT, Claude, Gemini, and generic Markdown exports today, and more sources are likely. Per-source policy belongs in one place, so when a new source lands we add a profile constant and a case to `resolve(source:model:)` rather than hunting for every `if`."

> "Intentionally flat: a profile is a set of Bool / enum toggles, not a closure bag. Rendering logic stays in the view; the profile just says which branches to take."

**評価**: 設計意図は明確で、拡張の土台として実用レベル。`model` パラメータも将来利用のために受け取っている。ただし現時点ではトグルが1つ (`collapsesForeignLanguageRuns`) のみ。

### 2.2 関連 commit 一覧

| SHA | 日付 | メッセージ | ブランチ状況 |
|-----|------|-----------|-------------|
| `09b321c` | 2026-04-24 | Pick render behavior per conversation source | vault/phase-c (未マージ) |
| `fc6a467` | 2026-04-26頃 | Detect conversation language for foreign-block grouping | vault/phase-c (未マージ) |
| `c8b193c` | 2026-04-24 | Render conversation images from the raw export vault | vault/phase-c (未マージ) |
| `4923795` | 2026-04-22頃 | ui: workspace polish — sidebar, identity, message bubbles, foreign-language blocks | main にマージ済み |
| `6c085c5` | 2026-04-22頃 | Add Source reader that renders transcripts from vaulted raw JSON | vault/phase-c (未マージ) |
| `3e9fc36` | 2026-04-30 | Phase 9 hotfix: ForeignLanguageGrouping prefix(-N) trap | vault/phase-c (未マージ) |
| `a3cef28` | - | Flip checkbox default to all-on, click to exclude | vault/phase-c (未マージ) |

### 2.3 ブランチ・worktree 棚卸し

**main から分岐しているブランチ** (`vault/phase-c-importer-audit` の系譜、30+ commits ahead):

```
main (92bf6d9) ← 全て未マージ
  └── vault/phase-c-importer-audit
        ├── Phase 0.5: primary_time expression index
        ├── Phase 2: Stats mode + SearchFilterSQL
        ├── Phase 4: Sidebar restructure
        ├── Phase 5 gamma: Stats chart selection
        ├── Phase 5.2: Passive source/model rows
        ├── Phase 6+7: .stats mode hardening
        ├── Phase 8: Dashboard sidebar filter
        └── Phase 9: ForeignLanguageGrouping prefix fix
```

**worktree 一覧** (`.claude/worktrees/`):

- phase4-sidebar, phase5-stats-detail, phase5-stats-drilldown
- phase5.1-dashboard-lock, phase5.2-passive-source-rows
- phase6-stats-mode-redefine, phase7-stats-user-prompt-filter
- phase8-dashboard-sidebar-filter, phase9-foreign-language-grouping-prefix-trap-fix
- stats-mode-impl, interesting-chaum-a48d33, busy-bardeen-87607b

全 worktree に `MessageRenderProfile.swift` が存在する。

### 2.4 未使用シンボル・dead code

- 「Render」「Renderer」「Transform」「Pipeline」「Rule」を名前に含む未使用 protocol / struct / enum は**見つからなかった**
- TODO / FIXME / XXX で render / source / model / layout 関連のものも**見つからなかった**
- `MessageRenderProfile` と `MessageRenderItem` は active に使用されている（ブランチ上）

### 2.5 結論

ジェンナの記憶にある「ソース × モデル別レンダリング切替」は `MessageRenderProfile` のこと。設計は放棄されたものではなく、**活発に使われている（ただし main にはまだ来ていない）**。新規フレームワーク設計は、この既存実装を土台にして発展させるのが適切。

---

## 3. 現象の精密な記述

### 3.1 Bug A — 数式の言語誤判定

**対象**: 会話「動物の頭と人間の胴体の神が世界中に存在する理由」(ID: `3a7be153`)、msg_index=31

**生テキスト（該当部分）**:

```markdown
集合 X 上の距離 d は次の性質を満たす関数：

1. d(x, y) ≥ 0（非負性）
2. d(x, y) = 0 ⇔ x = y（**同一性の判定**）
3. d(x, y) = d(y, x)（対称性）
4. d(x, z) ≤ d(x, y) + d(y, z)（三角不等式）
```

**現象**: 3行目が「Spanish」、4行目が「Polish」のラベルで折りたたみブロック化。1行目と2行目は正常表示。

**Root cause トレース**:

1. `ContentBlock.parse()` が各行を `.listItem` として解析
2. `ForeignLanguageGrouping.textContent(of:)` が `.listItem` からテキストを抽出
3. テキスト長が ≥20 文字のため `Detection.dominantLanguage()` が起動
4. `NLLanguageRecognizer` がラテン文字主体の数式記法 `d(x, y) = d(y, x)` を欧州言語と誤判定
5. 信頼度 ≥ 0.6 の閾値を超過し、Spanish / Polish として検出
6. システム言語（日本語）と異なるため「外国語」として折りたたみブロック化

**1行目・2行目が正常表示される理由の推定**:

- `d(x, y) ≥ 0（非負性）` は約19文字 → 20文字未満で検出スキップの可能性
- `d(x, y) = 0 ⇔ x = y（**同一性の判定**）` は `**` マーカー込みで約30文字だが、日本語部分（同一性の判定）の比率が高く、NLLanguageRecognizer が日本語と判定 → システム言語と一致

### 3.2 Bug B — 日本語本文がブロック化

**対象**: 会話「ケイン生物学の学習サポート」(ID: `71a6cc0d`)、msg_index=1

**raw export JSON 構造**:

```json
{
  "sender": "assistant",
  "content": [
    { "type": "text", "text": " " },
    { "type": "thinking",
      "thinking": "The user wants me to act as Madini, an 8-year-old girl spirit of the library, and support their study of Cain's Biology. Let me respond in a friendly, childlike but knowledgeable way in Japanese." },
    { "type": "text",
      "text": "わあ、ケイン生物学だね！✨ 図書館の中でもすごく分厚くて立派な本だよ！\n\nあたしはマディニ、この図書館の精霊だよ～！...\n\n---\n\n**どうやってサポートしようか？**\n\n..." }
  ]
}
```

**Python importer 後の `messages.content`**:

```
The user wants me to act as Madini, an 8-year-old girl spirit of the library, and support their study of Cain's Biology. Let me respond in a friendly, childlike but knowledgeable way in Japanese.わあ、ケイン生物学だね！✨ ...
あたしはマディニ、この図書館の精霊だよ～！本のことならなんでも知ってるから、一緒にがんばろうね！
...
```

thinking ブロックと text ブロックが結合され、構造的境界が消失。

**現象の発生メカニズム**:

1. 結合されたテキストを `ContentBlock.parse()` が解析
2. 第1パラグラフ: 英語モノローグ + 日本語応答冒頭が1つの `.paragraph` に → NLLanguageRecognizer が英語と判定 → システム言語（英語）と一致 → **折りたたまれない**
3. 第2パラグラフ以降: 純粋な日本語 → NLLanguageRecognizer が日本語と判定 → システム言語（英語）と異なる → **「Japanese」ラベルで折りたたみブロック化**

**意図との乖離**: 本来折りたたむべきは英語モノローグ（thinking）。しかし実際には日本語応答が折りたたまれ、英語モノローグが表示されている。完全に逆。

### 3.3 追加発見 — 日本語 monologue の存在

**サンプル**: 会話「20世紀の」(ID: `45e3926b`)、msg_index=3

**raw export JSON 構造**:

```json
{
  "sender": "assistant",
  "content": [
    { "type": "thinking",
      "thinking": "ユーザーは「20世紀の実在論から関係論へのパラダイムシフトを」と尋ねています。文が途中で終わっているようですが、おそらく「説明してほしい」という意味だと思われます。\n\nユーザーのプリファレンスでは:\n1. フランクな話し方\n2. 図書館の精霊である8歳の女の子マディニとして振る舞ってほしい\n\nこれは..." },
    { "type": "text",
      "text": "わぁ、むずかしい話だね! でもだいじょうぶ、図書館にはいーっぱい本があるから、説明できるよ！..." }
  ]
}
```

**重要な発見**: monologue が**日本語**で書かれている。raw JSON 上は `type: "thinking"` として構造的に分離されているが、Python importer が結合した後の flat text では、monologue と応答の両方が日本語であるため、**言語検出では原理的に区別不可能**。

### 3.4 追加サンプリング（A-3）

8件の claude ソース会話をサンプリングした結果:

| 会話 | monologue 言語 | monologue パターン | raw JSON での分離 |
|------|---------------|-------------------|-------------------|
| ケイン生物学 (71a6cc0d) | 英語 | "The user wants me to..." | `type: "thinking"` ✓ |
| 動物の頭 (3a7be153) | なし（この会話では monologue なし） | — | — |
| 20世紀の (45e3926b) | 日本語 | "ユーザーは...と尋ねています" | `type: "thinking"` ✓ |
| YouTube動画 (75049006) | 英語 | "The user wants me to...", "Jenna's...", "I need to..." | `type: "thinking"` ✓ |

**パターン**: モデルのバージョンやシステムプロンプトによって monologue の言語が変わる。しかし raw JSON では全て `type: "thinking"` として一貫して構造的に分離されている。

**False positive（本来折りたたまないべきものが折りたたまれている）**:

- Bug B の日本語応答テキスト
- Bug A の数式記法

**False negative（本来折りたたむべきものが折りたたまれていない）**:

- Bug B の英語モノローグ（システム言語が英語の場合、英語テキストは「外国語」ではないため）
- 日本語 monologue（会話の主要言語と同じため言語検出では区別不可能）

---

## 4. 現状の判定ロジック

### 4.1 処理パイプラインの全体像

```
archive.db (messages.content: flat text)
    │
    ▼
ContentBlock.parse()                  ← MessageBubbleView.swift 内 Parser struct
    │                                    行ベースのステートマシン
    │                                    paragraph / heading / listItem / code / math / table / etc.
    ▼
[ContentBlock]
    │
    ▼
ForeignLanguageGrouping.group()       ← ForeignLanguageGrouping.swift
    │                                    NLLanguageRecognizer per block
    │                                    システム言語との比較
    ▼
[MessageRenderItem]                   .block(ContentBlock) または
    │                                 .foreignLanguageGroup(language, blocks)
    ▼
MessageBubbleView.renderItem()        ← MessageBubbleView.swift
    │
    ▼
ForeignLanguageBlockView              ← 折りたたみ UI + 翻訳ボタン
```

### 4.2 main 上の判定ロジック（現行）

**ファイル**: `Sources/Views/Shared/ForeignLanguageGrouping.swift` (125行)

```swift
// group() — 外国語ブロックのグルーピング
static func group(_ blocks: [ContentBlock]) -> [MessageRenderItem] {
    let system = systemLanguage  // macOS システム言語
    // ... 各ブロックを走査
    let detected = Detection.dominantLanguage(of: block)
    if let lang = detected, lang != system {
        // システム言語と異なる → foreignLanguageGroup に追加
    } else {
        // システム言語と同じ or 検出失敗 → 通常ブロック
    }
}
```

**判定の入力と出力**:

| 項目 | 内容 |
|------|------|
| 入力単位 | ContentBlock 単位（段落、見出し、リストアイテム等） |
| 言語検出 | `NLLanguageRecognizer` (Apple NaturalLanguage framework) |
| 対象外ブロック | `.code`, `.math`, `.horizontalRule` → `textContent()` が nil 返却 |
| 最小文字数 | 20文字未満はスキップ |
| 信頼度閾値 | ≥ 0.6 |
| 比較対象 | `Locale.current.language.languageCode` (macOS システム言語) |
| キャッシュ | `NSCache<NSString, NSString>` (テキスト→言語コードの per-text キャッシュ) |

**テストカバレッジ**: なし（単体テストは存在しない）

**ソース依存性**: main 上では**ソース依存なし**。全ソース（Claude / ChatGPT / Gemini / Markdown）に同一ロジックが適用される。

### 4.3 ブランチ上の改善版

**ファイル**: `Sources/Views/Shared/MessageRenderProfile.swift` + 改修版 `ForeignLanguageGrouping.swift`

ブランチ（`vault/phase-c-importer-audit`）では以下が追加:

1. **profile ゲート**: `ForeignLanguageGrouping.items(from:collapseForeignRuns:nativeLanguage:)` で、profile の `collapsesForeignLanguageRuns` が false なら検出をスキップ
2. **会話レベル言語検出**: `primaryLanguage(ofMessageTexts:sampleLimit:minCharacters:minimumConfidence:)` が会話のメッセージテキストを最大5000文字サンプリングし、NLLanguageRecognizer で主要言語を検出
3. **nativeLanguage オーバーライド**: 検出された会話言語を「ネイティブ言語」として使用。日本語主体の会話では日本語が「ネイティブ」となり、日本語テキストは折りたたまれない

```swift
// ブランチ版 — profile ゲート付き
static func items(
    from blocks: [ContentBlock],
    collapseForeignRuns: Bool,
    nativeLanguage: NLLanguage? = nil
) -> [MessageRenderItem] {
    guard collapseForeignRuns else {
        return blocks.map { .block($0) }
    }
    return group(blocks, nativeLanguage: nativeLanguage)
}
```

**ブランチ版で修正される不具合**:

- Bug B (部分修正): 会話の主要言語を日本語と検出すれば、日本語テキストは折りたたまれない。英語モノローグは「外国語」として折りたたまれる。
- ChatGPT / Gemini 会話での不要な折りたたみ: profile が `.passthrough` なので完全にスキップ

**ブランチ版でも修正されない不具合**:

- Bug A: 数式の言語誤判定は NLLanguageRecognizer の問題であり、profile ゲートでは解決しない
- 日本語 monologue: 会話言語と同じ言語の monologue は言語検出では区別不可能

### 4.4 過去痕跡との関係

`MessageRenderProfile` は ForeignLanguageGrouping と同時に設計されており、monologue 判定を含む「より広い枠組み」として意図的に作られている。コメントに "when a new source lands we add a profile constant and a case to `resolve(source:model:)`" とあり、将来のソース追加を前提とした設計。現状の monologue 判定は、この枠組みの最初のユースケースとして組み込まれている。

---

## 5. 元の仕様の所在

### 5.1 文書検索結果

| 検索対象 | 結果 |
|---------|------|
| `docs/` ディレクトリ | main に存在しない |
| `AGENTS.md` — monologue/thinking/fold/collapse | 該当記述なし |
| `AGENTS.md` — render/renderer/source別/モデル別 | "If rendering interprets Markdown, math, or HTML, prefer designs that can still return to a raw/plain view" のみ（汎用ガイドライン） |
| `AGENTS.md` — AGENTS.md の過去 revision (git log -p) | render 関連セクションの追加・削除痕跡なし |
| `docs/investigations/` | ディレクトリ自体が存在しない |
| `docs/proposals/` / `docs/specs/` | 存在しない |

### 5.2 「ソースやモデルごとにレイアウトを選択して適用する仕様」

A0 の発掘結果と C-1 の検索結果を統合:

- **存在する**: `MessageRenderProfile` として commit `09b321c` で実装済み
- **所在**: `vault/phase-c-importer-audit` ブランチの `Sources/Views/Shared/MessageRenderProfile.swift`
- **完成度**: 実用レベルだが、トグルが1つのみ。設計は拡張を前提としている
- **main 未マージ**: phase 系ブランチ群がまとめて main に来ていない状態

仕様文書としての記述は存在しないが、コード内コメントが仕様の役割を果たしている。

---

## 6. 既存ソースのレンダリング差異の棚卸し

### 6.1 各層の分岐状況

| 層 | Claude | ChatGPT | Gemini | Markdown |
|----|--------|---------|--------|----------|
| **Parse（Import）** | `ClaudeTranscriptExtractor` | `ChatGPTTranscriptExtractor` | 未実装（Python importer のみ） | Python importer のみ |
| **Normalize** | flat text (thinking 結合) | flat text (DAG → chain 平坦化) | flat text | flat text |
| **View（ブランチ）** | `collapsesForeignLanguageRuns: true` | `.passthrough` | `.passthrough` | `.passthrough` |
| **View（main）** | 全ソース同一ロジック | 全ソース同一ロジック | 全ソース同一ロジック | 全ソース同一ロジック |
| **Visual** | SourceAppearance: 色・アイコン | SourceAppearance: 色・アイコン | SourceAppearance: 色・アイコン | SourceAppearance: 色・アイコン |

**想定外の場所での source 参照**: `DesignMockRootView.swift` で `renderProfile` を参照しているが、デザインモック専用で実機能には影響しない。

### 6.2 各社 export 形式の構造要素

**Claude** (`chat_messages[].content[]`):

| 要素 | parse で取り込み | 正規化で保持 | 備考 |
|------|-----------------|-------------|------|
| `type: "text"` | ✓ | ✓ (flat text) | 主要コンテンツ |
| `type: "thinking"` | ✓ (スキップ) | ✗ (Python が結合) | **root cause of Bug B** |
| `type: "redacted_thinking"` | ✓ (スキップ) | ✗ | |
| `type: "tool_use"` | ✓ | ✗ (flat text 化) | name + inputJSON |
| `type: "tool_result"` | ✓ | ✗ (flat text 化) | text + images |
| `type: "image"` | ✓ | ✗ | URL or base64 |
| `type: "artifact"` | ✓ | ✗ | identifier, title, kind, content |
| `attachments[]` / `files[]` | ✓ | ✗ | file_name, size, type |
| `model` (per-message) | ✓ | ✗ (conv-level のみ) | |

**ChatGPT** (`mapping[].message.content`):

| 要素 | parse で取り込み | 正規化で保持 | 備考 |
|------|-----------------|-------------|------|
| `content_type: "text"` | ✓ | ✓ (flat text) | parts[] 結合 |
| `content_type: "multimodal_text"` | ✓ | 部分的 | text + image_asset_pointer |
| `content_type: "code"` | ✓ | ✗ | Code Interpreter |
| `content_type: "execution_output"` | ✓ | ✗ | |
| `content_type: "tether_browsing_display"` | ✓ | ✗ | Web browsing |
| `content_type: "tether_quote"` | ✓ | ✗ | |
| `metadata.model_slug` | ✓ | ✗ (conv-level のみ) | per-message model |
| DAG 構造 (parent/children) | ✓ (longest chain) | ✗ | branch/retry 情報消失 |

**Gemini**:

| 要素 | parse で取り込み | 正規化で保持 | 備考 |
|------|-----------------|-------------|------|
| 全般 | Python importer のみ | flat text | Swift extractor 未実装 |
| 会話 ID | 合成 (Python) | ✓ | raw vault との紐づけ不可 |

### 6.3 ソース × モデル粒度の差異

現時点で具体的にモデル粒度の分岐が必要なケース:

- **Claude**: `content` 配列の `thinking` ブロックの有無はモデルによって異なる（extended thinking 対応モデルのみ）。しかし raw JSON 上では全て `type: "thinking"` で統一されているため、モデル分岐は不要。
- **ChatGPT**: `model_slug` が per-message で変わる場合がある（例: 会話中に GPT-4 → GPT-4o に切り替え）。しかし現時点でモデル別のレンダリング差異は確認されていない。
- **結論**: 現時点ではモデル粒度の分岐は不要。`source` 粒度で十分。`model` パラメータは将来のために受け取るが、dispatch には使わない（現在の MessageRenderProfile の設計と一致）。

---

## 7. 設計提案

### 7.1 設計目標

1. 各ソース × モデルに固有のレンダリング挙動を、コアエンジンを汚さずに追加できる
2. 新ソース・新モデル・新機能追加時の影響範囲を最小化
3. 設定として宣言的（ジェンナがコードを読まずに挙動を把握できる）
4. 既存の monologue ブロック化機能がこの枠組みの最初の利用例として収まる
5. 過去の `MessageRenderProfile` を再利用する
6. AGENTS.md の core-first design / 原本保全 / scale resistance 原則と整合

### 7.2 アーキテクチャ案の比較

#### 案 A: 構造的アノテーション + PreambleDetector

言語検出ベースの折りたたみを、構造パターンマッチングベースに置き換える。

**仕組み**:
- `PreambleDetector` が assistant メッセージの先頭ブロック群を走査
- Claude ソースのみ: 会話主要言語と異なる言語の先頭 `.paragraph` ブロックを preamble と判定
- heading / code / math / listItem / table は preamble 候補にならない
- `MessageRenderProfile` に `collapsesPreamble: Bool` トグル追加

**メリット**:
- Bug A 完全修正（listItem は preamble 候補外）
- Bug B 修正（ブランチの primaryLanguage 検出と組み合わせ）
- source ゲートにより ChatGPT / Gemini への誤適用なし
- テスタブル（純関数）

**デメリット**:
- 日本語 monologue には対応不可（normalized path では言語で区別できない）
- 先頭ブロック以外の monologue（メッセージ末尾に出現するケース等）には対応不可
- normalized path の限界（Python importer の結合問題）

#### 案 B: 共有 IR（中間表現）

normalized path と raw transcript path の出力を統一的な `RenderableBlock` enum に変換。

**メリット**:
- 単一レンダラーで両パスを処理
- `ContentBlock` / `ConversationTranscriptBlock` の重複排除

**デメリット**:
- 大規模リファクタ（`ContentBlock` は MessageBubbleView の 830+ 行に深く埋め込み）
- normalized path が生成できないブロック型（image, toolUse, artifact）が IR に含まれる → leaky abstraction
- AGENTS.md の「separation of layers」に反する（raw 層の語彙と view 層の語彙が結合）
- 両パスのバグ（A, B）は normalized path 固有。IR では解決しない

#### 案 C: Plugin per-provider

`SourceRenderPlugin` protocol を定義し、各プロバイダーが独自の annotation / rendering ロジックを登録。

**メリット**:
- 最大の拡張性。新プロバイダー = 新ファイル1つ
- 各プロバイダーのロジックが自己完結

**デメリット**:
- 4ソースに対して過度な抽象化（flat switch で十分）
- `AnyView` が型安全性と `Equatable` 準拠を破壊
- 既存設計意図（"profile is a flat struct, not a closure bag"）に反する
- premature abstraction（プロバイダー固有ニーズがまだ不明確）

#### 案 D: ハイブリッド（A + 段階的 IR 収束）— **推奨**

案 A を即時実装し、将来の IR 収束への道を残す。

**Phase 1**: PreambleDetector（案 A と同一）
**Phase 2**: `BlockAnnotation` enum を定義し、両パスの block に annotation を付与

```swift
enum BlockAnnotation: Hashable, Sendable {
    case preamble
    case thinking
    case response
    case toolContext
}

struct AnnotatedBlock<Block: Hashable & Sendable>: Hashable, Sendable {
    let block: Block
    let annotation: BlockAnnotation?
}
```

normalized path: `[AnnotatedBlock<ContentBlock>]`
raw transcript path: `[AnnotatedBlock<ConversationTranscriptBlock>]`

**Phase 3（将来、必要な場合のみ）**: Python importer が構造化コンテンツを保持するようになった場合、共有 IR に収束。annotation 層が既に共通語彙を提供するため、漸進的に移行可能。

### 7.3 比較表

| 基準 | 案 A | 案 B | 案 C | 案 D (推奨) |
|------|------|------|------|-------------|
| Bug A 修正 | ✓ | ✗ | ✓ | ✓ |
| Bug B 修正 | △ | ✗ | ✓ | △ |
| 日本語 monologue 対応 | ✗ | ✗ | △ | △ (raw path のみ) |
| 実装コスト | 小 | 大 | 中 | 小→中 (段階的) |
| 既存設計との整合 | ◎ | ✗ | ✗ | ◎ |
| AGENTS.md 原則 | ◎ | △ | △ | ◎ |
| テスタビリティ | ◎ | ○ | △ | ◎ |
| 将来拡張性 | ○ | ◎ | ◎ | ◎ |
| 宣言性 | ◎ | ○ | ○ | ◎ |

### 7.4 中間表現（IR）の必要性

**現時点では不要**。理由:

1. 2つのレンダリングパスは異なるデータ品質を提供する機能であり、バグではない
2. normalized path は常に lossy projection であり、IR で品質を上げることはできない
3. raw transcript path は既に正しく動作しており、IR のメリットがない
4. データの収束ではなく**アノテーション（意味付け）の共通化**が正しい抽象化ポイント

IR が有益になる条件: Python importer が構造化コンテンツ（thinking, tool_use 等）を messages テーブルに保持するようになった場合。この時点で normalized path のデータ品質が上がり、両パスの block 型を統合する意味が出てくる。

### 7.5 設定の保存場所と編集 UI

**推奨**: profile 解決はコード内 (`MessageRenderProfile.resolve(source:model:)`)。DB 保存不要。

理由:
- profile はソース値から決定論的に導出されるため、保存する意味がない
- ユーザー（ジェンナ）による per-conversation オーバーライドが必要になった場合のみ、view-layer schema に `rendering_overrides` テーブルを追加
- Settings 画面への追加は現時点で不要（デフォルト値が正しい）

将来「Claude の thinking ブロックの色を変えたい」「Gemini の citation を非表示にしたい」等の要望が出た場合:
1. `MessageRenderProfile` に新トグルを追加
2. reader のツールバーにギアアイコン → オーバーライド UI を追加
3. `UserDefaults` またはテーブルにオーバーライド値を保存
4. `resolve()` の戻り値をオーバーライドで上書き

---

## 8. 推奨案と段階的導入計画

### 8.1 推奨: 案 D（ハイブリッド段階的導入）

**根拠**:

| 設計目標 | 達成度 |
|---------|-------|
| コアを汚さない拡張性 | ◎ profile 追加のみ |
| 影響範囲最小化 | ◎ ソース追加 = profile 定数 + case 追加 |
| 宣言性 | ◎ Bool/enum トグルの集合 |
| monologue = 最初の利用例 | ◎ `collapsesPreamble` として収まる |
| 過去痕跡の再利用 | ◎ MessageRenderProfile をそのまま拡張 |
| AGENTS.md 整合 | ◎ layer 分離維持、原本保全 |

### 8.2 段階的導入計画

#### Phase 0: vault/phase-c を main にマージ（前提条件）

- `MessageRenderProfile`, 改良版 `ForeignLanguageGrouping`, `primaryLanguage()` を main に持ってくる
- Phase 9 の prefix(-N) fix も含む
- **規模**: 大（30+ commits、他機能も含む）
- **リスク**: 低（既に phase9 まで安定稼働実績あり）

#### Phase 1: PreambleDetector で monologue 判定を置き換え（最小）

新規ファイル:
- `Sources/Rendering/PreambleDetector.swift` — preamble 検出の純関数

変更:
- `MessageRenderProfile`: `collapsesForeignLanguageRuns` → `collapsesPreamble` に改名
- `MessageBubbleView.renderItems`: `ForeignLanguageGrouping.items()` → `PreambleDetector.detect()` に切り替え
- `ForeignLanguageBlockView` → `CollapsedBlockGroupView` に改名（UI 変更なし）

**規模**: 小（新規1ファイル + 既存2ファイル改修）
**リスク**: 低（pure function のため副作用なし、回帰テスト容易）
**効果**: Bug A 完全修正、Bug B 大幅改善（英語 monologue は正しく折りたたみ、日本語応答は展開）

#### Phase 2: raw transcript path に thinking ブロック表示を追加

変更:
- `ConversationTranscriptBlock` に `.thinking(String)` case 追加
- `ClaudeTranscriptExtractor`: thinking ブロックを skip ではなく emit
- `RawTranscriptBlockView`: thinking ブロックを collapsed-by-default の DisclosureGroup で表示
- `MessageRenderProfile` に `showsThinkingBlocks: Bool` 追加

**規模**: 中（4ファイル改修）
**リスク**: 低（raw transcript path は独立）
**効果**: raw transcript 表示で Claude の thinking を確認可能に。日本語 monologue も正しく表示（raw JSON の構造に依拠するため言語に依存しない）

#### Phase 3: 新プロバイダー機能の追加動線

例: ChatGPT の tool use 表示を改善

1. `MessageRenderProfile` に `toolCallDisplay: ToolCallDisplayLevel` (.hidden / .collapsed / .expanded) 追加
2. `.chatgpt` profile 定数を追加（`toolCallDisplay: .collapsed` 等）
3. `resolve()` の switch に `case "chatgpt"` 追加
4. `RawTranscriptBlockView` で profile を参照し、toolUse/toolResult の表示を切り替え

**規模**: 小（profile + view の修正）
**リスク**: 低

#### Phase 4（将来）: AnnotatedBlock 導入

- `BlockAnnotation` enum 定義
- 両パスで annotation を付与
- renderer が annotation を参照して collapse/fold 挙動を決定
- normalized path と raw transcript path の挙動が annotation 語彙で統一

**規模**: 中
**リスク**: 低（既存 behavior の refactoring、新機能なし）

#### Phase 5（将来）: ユーザー設定 UI

- reader ツールバーにギアアイコン追加
- per-conversation rendering override（"thinking ブロックを表示" 等）
- `UserDefaults` に保存

**規模**: 小
**リスク**: 低

### 8.3 過去痕跡の取り込みタイミング

| 過去実装 | フェーズ | 処理 |
|---------|---------|------|
| `MessageRenderProfile` | Phase 0 (main マージ) → Phase 1 (拡張) | 再活性化・拡張 |
| `ForeignLanguageGrouping.items()` (profile ゲート版) | Phase 0 (main マージ) → Phase 1 (置き換え) | Phase 0 で取り込み、Phase 1 で PreambleDetector に置き換え |
| `primaryLanguage()` | Phase 0 (main マージ) → Phase 1 (PreambleDetector が利用) | 再活性化・継続利用 |
| `ForeignLanguageGrouping.group()` (旧版) | Phase 1 で deprecated | Phase 1 後 1リリースサイクルで削除 |

---

## 9. ジェンナと相談すべき判断ポイント

### 1. 過去痕跡の処遇

`MessageRenderProfile` と改良版 `ForeignLanguageGrouping` は `vault/phase-c-importer-audit` ブランチにある。これらを main にマージすることが Phase 0 の前提条件。phase 系ブランチ群のマージ戦略（一括 or 段階的）はジェンナの判断が必要。

### 2. 推奨アーキテクチャ案の選択

案 D（ハイブリッド段階的導入）を推奨するが、以下の代替を検討:
- 案 A で止める（IR 収束の道を明示的に閉じる）
- 案 C（plugin）に進む（8+ ソースを見込む場合）

### 3. 中間表現（IR）を導入するか否か

現時点では**不要**と判断。導入条件は「Python importer が構造化コンテンツを messages テーブルに保持するようになった時」。この Python importer の改修予定があるかどうかで判断が変わる。

### 4. 設定の保存場所

推奨: コード内定数（`MessageRenderProfile.resolve()`）。per-conversation オーバーライドが必要になるまで DB/UserDefaults は不要。ジェンナが「特定の会話だけ thinking を表示したい」等の要望を持っているかで判断。

### 5. Phase 1 のスコープ確定

最小スコープ:
- PreambleDetector 新規作成
- MessageRenderProfile の `collapsesForeignLanguageRuns` → `collapsesPreamble` 改名
- MessageBubbleView の呼び出し元切り替え

拡張スコープ（Phase 1 に含めるか Phase 2 に分けるか）:
- `Sources/Rendering/` ディレクトリ作成とファイル移動
- ContentBlock / MessageRenderItem の MessageBubbleView からの分離
- CollapsedBlockGroupView への改名

### 6. 日本語 monologue への対応優先度

normalized path では日本語 monologue の検出が原理的に困難（言語で区別不可能、構造的境界が消失）。対応策:
- (a) raw transcript path を優先して使用し、normalized path は fallback に格下げ
- (b) Python importer を改修して thinking ブロック境界を保持
- (c) パターンマッチング（"ユーザーは" で始まる段落を monologue と推定）— fragile

どの戦略を取るかはジェンナの判断。(a) は表示切替 UI が必要、(b) は Python 側の作業、(c) は信頼性に課題。

### 7. 翻訳ボタンの今後

現在の ForeignLanguageBlockView は折りたたみ + 翻訳ボタンのセット。PreambleDetector に置き換えた後:
- preamble（monologue）に翻訳ボタンを維持するか？（英語 monologue を翻訳して読みたいケースがあるか）
- monologue 以外の外国語テキスト（例: 英語の引用文が日本語会話に出現）に対する翻訳機能はどうするか？
- ForeignLanguageGrouping を完全に廃止するか、monologue 検出とは独立した「外国語翻訳」機能として残すか？
