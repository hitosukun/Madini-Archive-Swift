# Phase 3a 追加調査レポート ── 重さ蓄積 + プロンプト見出しハイライト消失

- **日付**: 2026-05-06
- **調査ブランチ**: `feature/phase3-cache-strategy` (worktree: `madini-archive-phase3`)
- **前提**: [Phase 3 設計判断](../decisions/phase3-cache-and-preparse.md)、[Phase 1 調査](freeze-root-cause-investigation.md)、[Phase 2 実測](freeze-measurement-phase2.md)
- **スコープ**: Phase 3a 改修 (`CacheCostEstimation`, `LRUTrackedCache`, `CachePurgeCoordinator`, `MessageBubbleView` の 4 キャッシュ移行、`AppServices` への `MemoryPressureMonitor` 配線) と、その既存コードとの接合点

## ⚠️ 状況確認

調査対象は実態として **`feature/phase3-cache-strategy` ブランチのみ**に存在し、`main` (`e3297fb`) には未マージである。チャットコンテキストでは「Phase 3a を main にマージ後」と表現されているが、実機での観察は `/Applications/Madini Archive.app` (Phase 3a ビルドで上書き済み) を使った運用結果と解釈。Phase 3a コードに対する調査として進めて差し支えないが、main の実体は Phase 3a 未取り込みのままである点を認識合わせ要。

---

## 1. 症状の整理

ジェンナ報告:

| 症状 | Phase 3a の主目的との整合 |
|------|------------------------|
| フリーズが消えた | ✅ 達成 (一斉 purge → 段階 purge への切替が効いた) |
| しばらく使うとアプリが重くなる | 想定外の蓄積劣化 |
| 重い状態でプロンプト見出しのハイライトがつかなくなる | 重さと連動 (因果不明) |

「重い」と「ハイライト消失」が連動して観察されている事実が重要。同一原因の 2 症状なら以下の系列が考えられる:

- **メイン起因系列**: Phase 3a 内部 → 主にメインスレッド負荷増加 → SwiftUI 状態更新が drop/coalesce → ハイライト更新が落ちる
- **状態起因系列**: Phase 3a 内部 → ある内部状態が破損 → 装飾経路と選択経路が同時影響
- **無相関**: 重さは Phase 3a 由来だが、ハイライト消失はそれとは別の SwiftUI 内部問題で、観察上たまたま同期しているだけ

タスク 1〜5 で経路を切り分けた上で、第 7 章で仮説評価する。

---

## 2. タスク 1 ── プロンプト見出しハイライトの実装経路

### 2.1 該当コード

| ファイル | 行 | 役割 |
|---------|-----|------|
| `Sources/Views/macOS/DesignMockRootView.swift` | 4035-4088 | `promptRow(_:)` ── `DesignMockPromptRow` の構築 |
| `Sources/Views/macOS/DesignMockRootView.swift` | 4096-4101 | `rowIsSelected(_:)` ── `multiSelectedPromptIDs` か `selectedPromptID` で判定 |
| `Sources/Views/macOS/DesignMockRootView.swift` | 4199-4319 | `DesignMockPromptRow: View, Equatable` ── 行ビュー本体 |
| `Sources/Views/macOS/DesignMockRootView.swift` | 4315-4319 | `rowBackground` ── ハイライト色の決定 |
| `Sources/Views/Shared/LibraryHighlight.swift` | 33-45 | `HighlightedText` ── キーワードマッチの黄色ハイライト |
| `Sources/Views/Shared/LibraryHighlight.swift` | 47-82 | `LibraryHighlight.attributed(_:query:)` ── AttributedString 構築 |

### 2.2 「ハイライト」の二つの可能な意味

ジェンナ報告の「ハイライト」は二解釈ある:

**(a) 選択行の青い背景** (`rowBackground`, line 4315-4319):

```swift
private var rowBackground: Color {
    if isSelected { return Color.accentColor.opacity(0.22) }
    if isHovered { return Color.primary.opacity(0.06) }
    return Color.clear
}
```

`.background(rowBackground, in: RoundedRectangle(cornerRadius: 6, ...))` で適用。
**入力は `isSelected: Bool` スカラのみ**。AttributedString や Phase 3a の 4 キャッシュには一切触れない。

**(b) クエリマッチの黄色ハイライト** (`HighlightedText` → `LibraryHighlight.attributed`):

```swift
struct HighlightedText: View {
    let source: String
    @Environment(\.libraryHighlightQuery) private var query
    var body: some View {
        if query.isEmpty { Text(source) }
        else { Text(LibraryHighlight.attributed(source, query: query, color: color)) }
    }
}
```

毎 body 評価ごとに `LibraryHighlight.attributed` で AttributedString を新規構築。
**メモ化なし**、Phase 3a の 4 キャッシュとも無関係。

### 2.3 Phase 3a キャッシュとの依存関係

`InlineMarkdownCache.shared` / `InlineMathImageCache.shared` の呼び出し元を全文 grep:

```
Sources/Views/Shared/MessageBubbleView.swift:1398: ... InlineMarkdownCache.shared.render(text)
Sources/Views/Shared/MessageBubbleView.swift:1522: ... InlineMathImageCache.shared.rendered(for: latex, fontSize: ...)
```

両方とも **`MessageBubbleView` 内部のみ** から呼ばれている。`DesignMockPromptRow` / `HighlightedText` / `LibraryHighlight` のいずれからも呼ばれていない。

`blocksCache` / `renderItemsCache` は `MessageBubbleView.swift` の `private static` で、外部から触れないクロージャ。

### 2.4 結論

**プロンプト見出しハイライトの実装経路は、Phase 3a の 4 キャッシュのいずれにも依存していない**。

`rowBackground` の入力 `isSelected` は SwiftUI の `@State`/`@FocusState` 経由で更新される純粋なスカラ。`HighlightedText` の AttributedString も毎回新規構築され、キャッシュには触れない。

→ **仮説 D (キャッシュ層と attribute run の interaction) はコード経路レベルでは支持されない**。仮にハイライト消失が起きていても、Phase 3a キャッシュが直接の原因にはなりにくい。

---

## 3. タスク 2 ── CachePurgeCoordinator の検証

### 3.1 `LRUTrackedCache.purgeOldHalf` の挙動

実装 (`Sources/Views/Shared/LRUTrackedCache.swift:100-114`):

```swift
@discardableResult
func purgeOldHalf() -> Int {
    lock.lock()
    defer { lock.unlock() }
    guard !accessTime.isEmpty else { return 0 }
    let sorted = accessTime.sorted { $0.value < $1.value }
    let halfCount = sorted.count / 2
    guard halfCount > 0 else { return 0 }
    for (key, _) in sorted.prefix(halfCount) {
        underlying.removeObject(forKey: key as NSString)
        accessTime.removeValue(forKey: key)
    }
    return halfCount
}
```

| 観点 | 結果 |
|------|------|
| 空キャッシュ | guard で早期 return、no-op (✓) |
| 1 件のみ | `1/2 = 0`、no-op (✓) |
| 偶数件 | きっちり半分削る (✓) |
| 奇数件 | 切り捨て、古い側 floor(N/2) 削る (✓) |
| 削除順序 | accessTime 値 (UInt64 の monotonic counter) の昇順 ── 最古から (✓) |
| NSCache と accessTime の整合 | 両方から removeValue/removeObject、同じロック内で完結 (✓) |
| 削除後に同 key を再投入 | `setObject` が NSCache と accessTime 両方に新値を上書き (✓) |

### 3.2 削除後の再構築経路

例: blocksCache 内のあるメッセージ ID K が `purgeOldHalf` で削られた後の挙動 (`MessageBubbleView.swift:1004-1022`):

```swift
private var contentBlocks: [ContentBlock] {
    guard canRenderMessage else { return [.paragraph(message.content)] }
    if let cached = Self.blocksCache.object(forKey: message.id) {
        return cached.blocks
    }
    let parsed = ContentBlock.parse(message.content)
    Self.blocksCache.setObject(BlocksBox(parsed), forKey: message.id, cost: ...)
    return parsed
}
```

K 削除後の K に対するアクセスは `object(forKey: K)` が nil → 再 parse → 新 BlocksBox が cache に入る。**機能的に正常**。コストは「削った分だけ再 parse の同期実行が body 内で発生」。Phase 2 計測で「単発 1.6 ms (20k cap)」のオーダーなので、1 メッセージ単位では body block にならない。

ただし以下の場合に累積コストが顕在化:

- 50 messages 同時 visible で全部キャッシュ miss → 5 × 50 = 250 ms 級になる可能性
- スクロール中に visible 領域が連続変化 → 各フレームで複数 miss

### 3.3 依存キャッシュの孤児化リスク

`renderItemsCache` のキー: `"\(message.id)#\(collapse)#\(nativeLang)#\(useStructured)"`
`blocksCache` のキー: `message.id`

`blocksCache` 削除後も `renderItemsCache` 側に旧 entry が残ることがある。次回 body 評価時:

1. `renderItems` body 内で `Self.renderItemsCache.object(forKey: ...)` で hit → 旧 items を返す
2. その下流で個別 block を render する経路は `renderItems` が保持する `MessageRenderItem` (= block の参照) 経由なので **stale な block を見ている**
3. ただし `message.content` が **不変** (DB から fetch した不変オブジェクト) なので「stale = 古い content の block」ではなく「同じ content の block」── 値として一致

**孤児化はしているが意味的な不整合は起きない**。Phase 3 設計判断 A-5 の前提どおり。

### 3.4 `CachePurgeCoordinator.purgeAll` のロック挙動

実装 (`Sources/Views/Shared/CachePurgeCoordinator.swift:55-69`):

```swift
@discardableResult
func purgeAll() -> [(name: String, removed: Int)] {
    lock.lock()
    defer { lock.unlock() }
    registrations.removeAll(where: { $0.cache == nil })
    var results: [(String, Int)] = []
    results.reserveCapacity(registrations.count)
    for reg in registrations {
        results.append((reg.name, reg.purge()))
    }
    return results
}
```

| 観点 | 結果 |
|------|------|
| coordinator lock の保持期間 | 全 4 cache の purge 完了まで (~ms オーダー) |
| 内部の `reg.purge()` がさらに cache lock を取得 | 直列、デッドロックなし |
| 同時 purgeAll 呼び出し | 第 2 呼び出しは coordinator lock 待ち (シリアライズ) |

**問題点 (軽微)**: coordinator lock を保持したまま 4 つの cache の lock を順次取得 → 並列処理機会を失う。だが実質的に呼び出し元は単一 (DispatchSource 上の `.main` queue)、かつ各 purge は数 ms なので、現状のロック設計は妥当。

### 3.5 register の冪等性

ドキュメントコメントは「Idempotent on the same instance — re-registering an already-tracked cache is harmless」と書いているが、実装はそうなっていない:

```swift
func register<Value: AnyObject>(_ cache: LRUTrackedCache<Value>) {
    lock.lock()
    defer { lock.unlock() }
    registrations.append(...)  // ← 重複しても append する
}
```

同じ cache を 2 回 register すると、`purgeAll` で同 cache の `purgeOldHalf` が 2 回呼ばれる。1 回目で半分、2 回目で残りの半分の半分 → 計 75% drop となる。
ただし実用上、registration は `static let` の lazy init 内 (一度きり) のみ。**現状の呼び出し方では発火しない**ものの、ドキュメントと実装の食い違いは将来のバグ温床。修正フェーズで明示的な dup-check を入れるか、コメントを実装に合わせて訂正するか判断要。

### 3.6 NSCache 自身のメモリ圧力応答との重複

NSCache は **OS のメモリ圧力イベントに自動的に応答する** (Apple ドキュメント「The NSCache class incorporates various auto-eviction policies」、実装は opaque)。我々の `MemoryPressureMonitor` は同じ `.warning` イベントを聞いて `purgeOldHalf` を呼ぶ。

つまり 1 回の warning に対して:
1. NSCache が独自判断で entry を削る (実装次第、部分削除〜全削除の幅あり)
2. 我々の `purgeOldHalf` が accessTime の古い半分を削る (NSCache に対しては no-op になる可能性が高い、accessTime 側だけ削れる)

**結果として「半分削る」設計の意図が部分的に達成されない**可能性がある。NSCache 側で大胆に entry が消えていれば、我々の partial eviction は実質「accessTime のクリーンアップ」だけになる。

これは仮説 A の補足懸念だが、当初指摘の「過剰または破壊的」とは違って、**「逆に効果が薄れる」方向の懸念**。

### 3.7 結論 (タスク 2)

`CachePurgeCoordinator` 単体の eviction logic にはバグも edge case の問題もない。仮説 A (過剰・破壊的) は logic レベルでは **支持されない**。
ただし、

- NSCache 自身の自動応答との重複により、設計意図 (= partial eviction で freeze 回避) が薄れている可能性
- register の冪等性についてのドキュメントと実装の不整合 (将来バグの温床)

の 2 点が要修正候補。

---

## 4. タスク 3 ── cost 見積もりの妥当性分析

### 4.1 `costForText`

```swift
static func costForText(_ text: String) -> Int {
    return text.utf8.count * 4
}
```

**Phase 2 のベンチ結果から推定する実値**:

| ケース | utf8 byte | cost (×4) | 推定実メモリ | 倍率 |
|------|-----------|-----------|-------------|------|
| 短い英文段落 (200 chars) | 200 | 800 | ~600-1000 | ≈ 1× |
| 平均日本語段落 (500 chars) | ~1500 | 6000 | ~2000-4000 | **過大 1.5-3×** |
| 大型日本語段落 (5000 chars) | ~15000 | 60000 | ~20000-40000 | **過大 1.5-3×** |
| 20k cap message | ~60000 | 240000 | ~80000-160000 | **過大 1.5-3×** |

**結論**: テキスト系コストは **保守的 (= 過大評価)**。NSCache は「過大評価された cost」で eviction を判断するため、**実メモリ使用量より早くキャッシュが圧迫されたと判断する**。これは過小評価 (= 実メモリ超過) の方向ではない。仮説 B「cost 見積もり甘 → warning 頻発」は textForText 側では支持されない。

### 4.2 `costForBlocks`

```swift
case .paragraph(let s), .blockquote(let s), .math(let s):
    total += costForText(s)  // ×4
```

`[ContentBlock]` は AttributedString ではなく、Swift enum + String の素朴な構造。AttributedString の attribute run table のオーバーヘッドは無いため、実値は文字列の utf8 size 程度。

**推定**: 実メモリ ≈ utf8 × 1.2、cost = utf8 × 4 → **過大 3-4×**。

`blocksCache` 32MB cap に対して、実メモリは 8-10MB しか使っていない可能性がある。**budget 余ってるのに早期 eviction が起きうる**。これも過大評価方向で、warning 頻発の原因にはならない。

### 4.3 `costForImage` ── ★ 重要発見

```swift
#if os(macOS)
static func costForImage(_ image: NSImage) -> Int {
    let s = image.size
    return costForImage(width: Int(s.width.rounded()), height: Int(s.height.rounded()))
}
#endif

static func costForImage(width: Int, height: Int) -> Int {
    return max(width, 1) * max(height, 1) * 4
}
```

**問題**: `NSImage.size` は **論理 point 値 (display-resolution-independent)**。Retina ディスプレイでは実ピクセル = point × backingScaleFactor (= 2 の場合が一般的)。

| 例 | logical size | 実 pixel size | cost 計算 | 実バックアップ store |
|----|-------------|--------------|-----------|---------------------|
| 数式 small | 60×30 pt | 120×60 px (Retina @2x) | 60×30×4 = 7,200 | 120×60×4 = **28,800** |
| 数式 medium | 200×40 pt | 400×80 px | 200×40×4 = 32,000 | 400×80×4 = **128,000** |
| 数式 large | 400×80 pt | 800×160 px | 400×80×4 = 128,000 | 800×160×4 = **512,000** |

**Retina ディスプレイで cost が実メモリの 4 分の 1 しか測定できていない**。`InlineMathImageCache` の totalCostLimit = 16 MB は、実態として **64 MB 近くまで保持し続ける可能性がある**。

さらに、`MathImage.asImage()` が返す `NSImage` には `bitmapImageRep` だけでなく `cgImage` 表現が二重に保持される実装があり得る (画像ライブラリ次第)。実バックアップはさらに大きい可能性。

**仮説 B の根拠**: `gemini_2026-03-21` のような数式重視スレッドで、`InlineMathImageCache` が 16 MB 上限のつもりで 64 MB+ を実消費 → 実メモリ圧力高 → OS の memory pressure warning 発火頻度上昇 → cache thrash → **重さの蓄積**。

### 4.4 totalCostLimit 128 MB が実際に何 MB か

| キャッシュ | 公称 cap | 実メモリ推定倍率 | 実メモリ cap |
|----------|---------|----------------|------------|
| InlineMarkdownCache (text) | 64 MB | 0.3× (過大評価) | ~20 MB |
| blocksCache (blocks) | 32 MB | 0.3× (過大評価) | ~10 MB |
| renderItemsCache | 16 MB | 0.3× (過大評価) | ~5 MB |
| InlineMathImageCache (image) | 16 MB | **4×** (過小評価、retina) | **~64 MB** |
| **合計実メモリ** | 128 MB | | **~99 MB** |

合計値は 128 MB を超えないが、**配分が極端に偏る**。テキスト系は budget 余って eviction を要しないのに、画像系だけが実メモリ超過 → 単体で memory pressure warning を引きうる。

### 4.5 結論 (タスク 3)

仮説 B「cost 見積もりが甘く warning が頻発」は **画像系のみ強く支持される** (Retina 4× 過小評価)。テキスト系は逆に過大評価で問題なし。

`gemini_2026-03-21` のような **数式を多用するスレッドを開く操作** が「重くなる」操作と相関するか、**ジェンナの観察結果での確認が必要**。

修正方針 (タスク 9 で詳述): `costForImage(_ image: NSImage)` で `image.recommendedLayerContentsScale(0)` または backingScaleFactor を掛ける。

### 4.6 追加実測の要否

仕様レベルの分析だけで「画像コスト過小評価」は確定できる。実測まで要さない。
ただし「実際に warning が頻発しているか」は仕様レベルでは断定できない。Instruments の Memory template で Madini Archive 起動 → `gemini_2026-03-21` を 30 分操作中の memory_pressure_event 発火回数を見れば確定する。これはジェンナ環境での実測タスク (Phase 2 のベンチ流用ではカバー不可)。

---

## 5. タスク 4 ── スレッド安全性の検証

### 5.1 `LRUTrackedCache` の lock 範囲

各メソッドが `lock.lock(); defer { lock.unlock() }` で全ボディを覆う:

| メソッド | lock 範囲 | 危険な共有状態 |
|---------|----------|--------------|
| `setObject(_:forKey:cost:)` | NSCache write + accessTime write + counter | 全部 lock 内 (✓) |
| `object(forKey:)` | NSCache read + accessTime write/remove + counter | 全部 lock 内 (✓) |
| `removeObject(forKey:)` | NSCache write + accessTime write | 全部 lock 内 (✓) |
| `purgeOldHalf()` | accessTime read+sort + 反復 NSCache write + accessTime write | 全部 lock 内 (✓) |
| `removeAllObjects()` | NSCache write + accessTime write | 全部 lock 内 (✓) |
| `trackedCount` (computed) | accessTime read | lock 内 (✓) |

**ロック範囲は十分**。`accessTime` の read/write は常に lock 内で行われる。

### 5.2 `lruOrder` の race 検証

仮説 C で言及された `lruOrder` 配列という名前のフィールドは、実装には **存在しない**。実装は `accessTime: [String: UInt64]` Dict + `counter: UInt64` の組合せ。
仮説 C の「`lruOrder` 配列の更新が race している」は、実装ベースで再評価すると「`accessTime` Dict の更新が race しているか」と読み替える。`accessTime` の全 mutation は lock 内 → race なし (✓)。

### 5.3 call site 列挙

Phase 3a の 4 キャッシュの呼び出し元:

| キャッシュ | 呼び出し元 | スレッド |
|----------|----------|---------|
| `MessageBubbleView.blocksCache` | `MessageBubbleView.contentBlocks` (computed property) | SwiftUI body eval = `@MainActor` |
| `MessageBubbleView.renderItemsCache` | `MessageBubbleView.renderItems` (computed property) | SwiftUI body eval = `@MainActor` |
| `InlineMarkdownCache.shared.cache` | `InlineMarkdownCache.shared.render(_:)` from `MessageBubbleView.renderInlineRich()` | body eval = `@MainActor` |
| `InlineMathImageCache.shared.cache` | `InlineMathImageCache.shared.rendered(for:fontSize:)` from `MessageBubbleView` (line 1522) | body eval = `@MainActor` |
| 全 cache の `purgeOldHalf()` | `MemoryPressureMonitor` の DispatchSource event handler (queue: `.main`) | main thread |

**現状の Phase 3a では、全ての cache 呼び出しが main thread から行われる**。NSLock を取る race は実質発生しない。

ただし ── **Phase 3b で `Task.detached(priority: .userInitiated)` から `prewarmCache(for:)` を呼ぶ計画**がある (Phase 3 計画文書 B-2)。Phase 3b 着手時に再検証が必要。具体的には:

- `LRUTrackedCache.setObject` を background thread から、`object(forKey:)` を main thread から、同時に呼ぶケースが発生
- NSLock は再入不可 (`NSRecursiveLock` ではない)。**現実装で background → main の組合せは安全** (lock の用途として正規)
- 同 key 同時 access の場合、勝者が勝つ ── どちらが勝ってもキャッシュ整合性は保たれる
- accessTime の counter 競合 → wrap-around は起きるが overflow なし (`&+=`)

### 5.4 結論 (タスク 4)

**現 Phase 3a 実装には race condition なし**。仮説 C は **支持されない**。
Phase 3b 着手時に「Task.detached → setObject、main → object」のシナリオを再評価すれば良い。

---

## 6. タスク 5 ── attribute run interaction の検証

### 6.1 タスク 1 から繰り越した結論

「プロンプト見出しハイライト」の実装経路 (`DesignMockPromptRow.rowBackground` + `HighlightedText`) は Phase 3a の 4 キャッシュに依存していない (タスク 1, §2.4)。

### 6.2 キャッシュ miss → 再構築での attribute run 復元

`InlineMarkdownCache.render(_:)` の miss path:

```swift
let parsed = (try? AttributedString(markdown: text, options: Self.options)) ?? AttributedString(text)
cache.setObject(Box(parsed), forKey: text, cost: ...)
return parsed
```

`AttributedString(markdown:options:)` は **input string に対して純粋** (同じ input → 同じ attribute run 構造)。再構築インスタンスは構造的に元のインスタンスと等しい。SwiftUI の `Text(_: AttributedString)` は AttributedString の値ベース等価性で diff するため、**再構築されたインスタンスを「同じ」と認識する**。

### 6.3 SwiftUI 差分検知の懸念

仮説 D の懸念「SwiftUI が再構築 entry を『同じ』と判定しない経路」を仕様レベルで確認:

- `AttributedString` は `Equatable` 値型 (Foundation 提供)
- `Text(_: AttributedString)` の identity は AttributedString の content による
- 再構築 instance は value-equal なので diff 上は no-op
- ただし `Text` が `AttributedString` を保持する内部表現は不明 (Apple 実装) ── **仕様上は同一視**される

理論上 AttributedString は inherit AttributeContainer references を持つこともあり、**reference identity ベースの最適化が SwiftUI 内部にあれば**再構築 entry は別物扱いになる可能性。だが Apple は公式に「value-based identity」と明記しており、その仮定は弱い。

### 6.4 結論 (タスク 5)

**仮説 D を支持するコード経路上の証拠は無い**。プロンプト見出しハイライトは Phase 3a キャッシュに触れず、AttributedString の再構築は構造的等価性を保つ。

ハイライト消失と Phase 3a キャッシュの接続点は **存在しない (= 直接因果ではない)**。

---

## 7. 仮説の評価

| 仮説 | 内容 | 評価 | 根拠 |
|------|------|------|------|
| **A** | CachePurgeCoordinator の半分 eviction が過剰または破壊的 | **Low** | logic は正しい。NSCache 自動応答との重複 (§3.6) が「効果薄れ」方向の副次懸念 |
| **B** | cost 見積もりが甘く warning 頻発 | **Medium-High** | テキスト系は過大評価で OK。**画像系は Retina で 4× 過小評価** (§4.3)。math-heavy スレッドで warning 頻発の有力根拠 |
| **C** | LRUTrackedCache のスレッド安全性に穴 | **Low** | 全 call site が main thread。NSLock の使用は正規。Phase 3b で要再検証 |
| **D** | キャッシュ層と attribute run の interaction で highlight 異常 | **Very Low** | コード経路レベルでハイライトは 4 キャッシュのいずれにも触れない (§2.4, §6.1) |
| **E (新規)** | メイン スレッド starvation で SwiftUI 状態更新が drop/coalesce | **Medium** | B が真なら frequent purge → 4 cache × O(n log n) sort on `.main` → main thread 占有 → SwiftUI batching 異常 → 「重い」と「ハイライト来ない」が同期的に起きる説明可能 |

### 7.1 仮説 B + E の連鎖が最有力

- **B** が真 (画像 cost 過小評価) → memory pressure warning が想定より頻発
- 各 warning で `MemoryPressureMonitor.eventHandler` が `.main` queue で fire
- `purgeAll` が main thread で 4 cache を順次 sort + purge
- 1 回あたり ~ms オーダーだが、warning が秒単位で連発すると累積
- main thread 占有が増えると SwiftUI の状態反映が遅延 / drop
- 結果: 「重い」+「ハイライトが (その瞬間に) つかない」

この連鎖を裏付けるには **memory_pressure_event 発火頻度の計測** がほぼ必須。

---

## 8. ジェンナ観察待ちの分岐

ジェンナの予定観察結果ごとに、本レポートの仮説評価がどう更新されるか:

### 観察 1: 「重くなった」時にアプリ再起動するとハイライトが復活するか

| 結果 | 解釈 | 仮説評価への影響 |
|------|------|-----------------|
| 復活する | プロセス内の状態 (キャッシュ蓄積、ViewModel 蓄積、SwiftUI 内部状態) が原因 | E が強化、B も支持 |
| 復活しない | DB / disk 側の問題 (Phase 3a 改修ではない別要因) | A〜E すべて切り下げ、Phase 3a 範囲外を疑う |
| 一時復活してまたすぐ重くなる | キャッシュは fresh start するが warming で再発 → cost 見積もり起源 | **B が決定的**、修正フェーズで cost 修正を最優先 |

### 観察 2: アクティビティモニタでのメモリ量推移

| 観察 | 解釈 | 仮説評価への影響 |
|------|------|-----------------|
| 累積で >500 MB に達する | Phase 3a 想定 (128 MB cap) を大きく超える ── 画像 cost 過小評価で支持 | **B が確定**、修正最優先 |
| 100-200 MB で頭打ち | cap が機能している (image でも 4× 過小評価で 64 MB なら合計 ~120 MB の上限あり) | B は「緩い」レベル、E が独立要因の可能性 |
| 200-500 MB で頭打ち | 画像 cost 過小評価が 4× より大きい (multiple representation 等) | B 確定 |

### 観察 3: 「重くなる」操作の特定

| 重くなる操作 | 解釈 | 仮説評価への影響 |
|------------|------|-----------------|
| 数式 / 画像多めの会話切替 | InlineMathImageCache の蓄積 | **B が決定的** (Retina 4× が起源) |
| 長文会話の連続オープン | InlineMarkdownCache or blocksCache 蓄積 | テキスト系は過大評価なので、別経路 (Phase 3a 範囲外、もしくは renderItemsCache のキー設計) を疑う |
| 検索 (toolbar 入力) | キャッシュとは別系統 | Phase 3a 範囲外 |
| スクロール | LineBreakHints / softWrap 等の per-paragraph cost | Phase 3a 範囲外 |

### 観察 1〜3 のいずれかだけでも判断確定可能

- 観察 1 で「復活する」+ 観察 3 で「数式会話で重い」→ **B が決定的、修正フェーズへ**
- 観察 2 で「>500 MB」→ **B が決定的**
- 観察 1 で「復活しない」→ **Phase 3a 範囲外、別調査フェーズへ移行**

---

## 9. 修正フェーズへの引き継ぎ事項

### 9.1 仮説確定後の修正候補

**B が確定した場合 (最有力ケース):**

| 修正 | 場所 | コスト |
|------|------|------|
| `costForImage(_ image: NSImage)` を retina 対応 (`recommendedLayerContentsScale` か `bestRepresentation.pixelsWide/High`) | `Sources/Views/Shared/CacheCostEstimation.swift` | 小 |
| `InlineMathImageCache.totalCostLimit` の妥当性再検討 (実 64 MB を許容するか、cap 縮小か) | `Sources/Views/Shared/MessageBubbleView.swift:1745` 周辺 | 小 |
| 画像系 entry の cost test (retina 想定値) | `Tests/MadiniArchiveTests/CacheCostEstimationTests.swift` | 小 |

**E が独立に観察された場合:**

| 修正 | 場所 |
|------|------|
| `purgeAll` を `.main` queue から外す (e.g. `.userInteractive` background queue) | `Sources/Views/Shared/CachePurgeCoordinator.swift:113` (`queue: .main` → 別 queue) |
| ただし NSLock の cross-thread 利用が正常に効くことを再確認 | タスク 4 §5.3 を Phase 3b 着手時にも適用 |

**A の副次懸念 (NSCache 自動応答との重複):**

| 修正 | 場所 |
|------|------|
| register の冪等性ドキュメントと実装の整合 (dup-check 追加 or コメント訂正) | `Sources/Views/Shared/CachePurgeCoordinator.swift:34-48` |
| NSCache 自動応答との重複が「partial eviction の意図薄れ」を起こすか実測 | (実測タスク、要 Instruments) |

### 9.2 推奨アクション順序

1. **ジェンナ観察 1〜3 を待つ** (本調査の確定材料)
2. 観察結果に応じて以下を分岐実行:
   - B 確定 → 9.1 の B 修正セットを Phase 3a-fix として起票
   - 観察 1「復活しない」→ Phase 3a 範囲外調査 (別フェーズ起票)
3. **B が確定しても** Phase 3b の Bulk Pre-parse 設計と独立にロールバック可能なので、Phase 3b 着手判断と並行で進められる
4. ハイライト消失の真因が **Phase 3a 範囲外**だった場合の追加調査として、SwiftUI body eval throttling / state coalescing の観察 (Instruments の SwiftUI template) を別フェーズで検討

### 9.3 修正フェーズで触らないこと

- Phase 3a 以前から存在する 5 つ目の cache (`InlineMathSplitter.cache`, `MessageBubbleView.swift:1563`) ── 別フェーズで Phase 3a 同様の改修を判断
- LRUTrackedCache の lock 設計の根本変更 (Phase 3b の要件が出てから検討)
- NSCache → 自前 LRU への置き換え (Phase 3 設計判断 A-1 で却下済み、現状でも仮説 C の根拠なし)

### 9.4 本調査からの追加発見 (修正フェーズ起票候補)

- **register の冪等性矛盾** (§3.5) ── ドキュメントと実装の不整合修正 (低優先)
- **NSCache 自動応答との重複** (§3.6) ── 設計上の懸念、実測してから判断 (中優先)
- **画像 cost の Retina 4× 過小評価** (§4.3) ── 観察 2/3 で B が確定したら最優先

---

## 補遺: 本調査で精査したコード位置一覧

| ファイル | 行 | 役割 |
|---------|-----|------|
| `Sources/Views/Shared/CacheCostEstimation.swift` | 全体 | cost 見積もり実装 |
| `Sources/Views/Shared/LRUTrackedCache.swift` | 全体 | LRU + NSCache wrapper |
| `Sources/Views/Shared/CachePurgeCoordinator.swift` | 全体 | コーディネータと MemoryPressureMonitor |
| `Sources/Views/Shared/MessageBubbleView.swift` | 1004-1042 | blocksCache とその利用 |
| `Sources/Views/Shared/MessageBubbleView.swift` | 1183-1199 | renderItemsCache 定義 |
| `Sources/Views/Shared/MessageBubbleView.swift` | 2945-3000 | InlineMarkdownCache 全体 |
| `Sources/Views/Shared/MessageBubbleView.swift` | 1716-1797 | InlineMathImageCache 全体 |
| `Sources/Views/Shared/MessageBubbleView.swift` | 1398, 1522 | キャッシュ呼び出し点 |
| `Sources/Views/macOS/DesignMockRootView.swift` | 4035-4319 | プロンプト行と highlight |
| `Sources/Views/Shared/LibraryHighlight.swift` | 全体 | キーワード highlight |
| `Sources/Core/AppServices.swift` | (Phase 3a 改修部 8 行) | MemoryPressureMonitor 配線 |
