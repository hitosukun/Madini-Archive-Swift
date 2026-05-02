# Phase A — Wiki Reader 振り返り

実施: 2026-05-02
担当: Claude Code (worktree `claude/brave-chatterjee-4a6474`)
発注: ジェンナ (handoff: `docs/handoff/PhaseA-WikiReader.md`)
完了報告: `docs/handoff/PhaseA-WikiReader-completion.md`
受け入れ基準: 9/9 達成

## 時系列

すべて 1 セッション内で完走。実装中に発覚した既存問題への対処と、
ジェンナの実 vault での動作確認サイクルが含まれる。

| フェーズ | 内容 |
|---|---|
| 0. 探索 | handoff doc 読了 → Explore agent 3 本並列で migration 状態 / Settings 構造 / 既存リポジトリパターンを調査 → Plan agent で A1 実装計画を策定 |
| A1 | wiki_vaults migration、Models、protocols、GRDB 実装、Mock、19 テスト |
| A2 | FrontmatterParser、ObsidianMarkdownParser、Wikilink モデル拡張、29 テスト |
| A3 | WikiIndexer、WikiIndexCoordinator、FSEventsMonitor、AppServices 統合、21 テスト。ジェンナが /tmp に仮 vault を作って `testManualExternalVaultIsReadOnly` で hash diff 検証 |
| (中断) | main ブランチに過去の中断 merge の残骸 (unmerged index entries) が残っていてビルド失敗。HEAD commit 自体は健全だったので作業ツリーを `git reset --hard HEAD` で復旧 |
| A4 | MarkdownUI 依存追加、Settings タブ、独立 window (⇧⌘W)、3 ペイン WikiBrowserView、production sidebar への統合、13 preprocessor テスト |
| (修正 1) | TCC re-prompt 問題 → 「bookmark を取得しているが resolve していない」と診断、WikiVaultAccessor 追加、7 テスト |
| (修正 2) | ジェンナが Sidebar の Wikis をクリックしても placeholder が出る → 製品で使われているのが MacOSRootView ではなく DesignMockRootView だったと判明、DesignMock 側の wikisPlaceholderSplit を WikiBrowserView に置換 |
| (修正 3) | ジェンナの実 vault で `[[コルバ]]` が解決されない → 命名規則が `rgn_0007_コルバ.md` (id-prefixed) と判明、WikilinkResolver の precedence を拡張、12 テスト |
| (UX) | ファイルツリーのフォルダ行が disclosure indicator しか反応しない → 行全体クリックで展開する版に書き直し |
| A5 | WikiSearchQueryParser (`type:chr` 構文)、ファイルツリー上部に検索バー、17 テスト |
| A6 | MadiniURL パーサ、MadiniURLHandler、Info.plist URL Types、scene.onOpenURL 連携、14 テスト |
| (TCC 真因) | TCC 大量 prompt が修正後も継続 → 調査の結果、起動毎の Documents prompt は Wiki ではなく既存 auto-intake (~/Documents/Madini Archive Intake/) が原因と判明。intake folder を /tmp に変更で解消 |
| docs | wiki-dev-notes、PhaseA-WikiReader-completion、本振り返り |
| merge | main へ `--no-ff` merge (`26e7355`)、push 未実施 |

最終的に 132 wiki テストが pass、合計 13 commits が main に着地した。

## 設計判断

### WikiRepository を 2 つに分離

handoff doc では単一 `WikiRepository` だったが、実装段階で
`WikiVaultRepository` (archive.db、vault 登録) と
`WikiPageRepository` (per-vault .db、ページ索引) に分離した。

**理由**: 異なる DB ファイル、異なるライフサイクル、異なる呼び出し元。
混ぜるとリポジトリ実装が `[String: DatabaseQueue]` を抱える羽目になり、
既存の他のリポジトリの単純さ (1 リポジトリ = 1 DatabaseQueue) と一貫しない。

ジェンナの事前承認を得てから着手。

### WikiBrowserView を独立 window としても、main window 内でも見える形に

handoff doc の「サイドバー Wikis から登録 vault が見える」は、
main window 内統合とも独立 window とも読めた。最終的に両方で見られる形:
- 独立 window (⇧⌘W、Wikis メニュー、production sidebar の WikisSidebarSection)
- main window 内 (DesignMockRootView の wikisPlaceholderSplit detail に埋め込み)

両ルートとも同じ WikiBrowserView を使う。state は per-instance で衝突なし。

### WikilinkResolver の precedence 拡張

Obsidian 標準の挙動 (filename 完全一致 / shortest path) では、ジェンナの
vault の `[[コルバ]]` → `rgn_0007_コルバ.md` が解決できない。
6 段階の precedence (完全パス → filename stem → title → suffix `_<target>` → 
underscore token → prefix) で対応。

**理由**: ジェンナの vault は id-prefixed naming convention で、
[[label]] でリンクされている。Obsidian 互換よりも実用性を優先。
12 テストで precedence 順序を保証。

### WikiVaultAccessor で起動時 bookmark resolve

vault 登録時に bookmark を取得していたが、resolve をしていなかった。
WikiVaultAccessor で resolve + scope 開始 + URL キャッシュ + stale 時の refresh
を担当させ、AppServices 経由で全 view に提供。

**理由**: bookmark 取得は registerVault で 1 回限り、resolve は起動毎に必要、
というライフサイクルの非対称性を 1 箇所に集約。

(ただし後述の通り、App Sandbox オフ環境では bookmark 自体が
TCC 抑止に効かないため、結果的に開発時の prompt 抑止には直接寄与しなかった)

## 想定外だったこと

### 1. main ブランチに過去の中断 merge の残骸

worktree 開始時、main の HEAD commit (`d4e35c3`) は健全だったが、
**main checkout の作業ツリー** に「中断された merge の残骸」が残っていた:
- `MERGE_HEAD` / `MERGE_MSG` などのメタデータは削除済み
- でも `git ls-files -u` で 12 ファイルが unmerged 状態
- → ジェンナが Xcode で main を開くとビルド失敗

これは Phase A 着手前から存在していた状態 (誰かが merge 実行 → conflict 解消途中で
中断 → メタデータだけ削除して放置)。`git reset --hard HEAD` で作業ツリーを HEAD に
戻して解決。HEAD コミット自体は不変、commit graph は無変化。

**学び**: worktree のベース commit が健全でも、別 checkout の作業ツリー状態は
独立。「main がビルドできない」と言われたら、まず checkout 状態と HEAD commit を
切り分ける。

### 2. App Sandbox オフでの Security-Scoped Bookmark の事実上の無効化

ジェンナから「vault 登録後にアプリを再起動するたびに書類フォルダ permission
ダイアログが出る」と報告。最初は bookmark resolve 不在が原因と仮説して
WikiVaultAccessor を実装したが、ジェンナの環境では prompt が消えなかった。

調査の結果、Apple の仕様として:
- App Sandbox オフ → security scope は意味を持たない
- TCC は code signing identity + path で承認をキャッシュ
- Xcode の "Sign to Run Locally" だと build path や Info.plist 変更で
  identity が変動 → TCC 再発火

つまり「bookmark を resolve すれば TCC が抑止される」は **Sandbox 前提の挙動**。
配布版では正規対応として動くが、開発時の Xcode 起動では別の対処
(Full Disk Access) が必要だった。

**学び**: TCC 関連の挙動は App Sandbox 前提の挙動と非 Sandbox 前提の挙動が
別物。Phase A は App Sandbox オフのまま走ったので、bookmark の正規対応と
開発時の TCC 抑止は別の問題として扱うべきだった。

### 3. Documents prompt の真因が Wiki ではなく auto-intake

修正と動作確認を繰り返しても prompt が消えず、最終的に vault を /tmp に
動かしても prompt が出続ける状態に。原因は **既存の IntakeService が
~/Documents/Madini Archive Intake/ を起動毎に監視している** こと。
Phase A 以前から存在していた挙動が今回の検証で初めて顕在化した。

intake folder を /tmp/madini-intake に向ける (UI からも CLI からも変更可能)
ことで解決。

**学び**: 「Wiki 機能を直すと TCC prompt が消えるはず」という仮説に
固執しすぎていた。ダイアログの文言「書類フォルダ」が Documents 全体への
prompt であることに早めに着目していれば、Wiki vault が `~/小説/` でも
`/tmp/` でも prompt が出る = Wiki と無関係、と切り分けられたはず。

### 4. プロダクションの sidebar が DesignMockRootView だった

A4 の最初の動作確認時、ジェンナの sidebar が「Wikis is coming soon」
placeholder を表示していた。私が統合したのは MacOSRootView の
UnifiedLibrarySidebar だったが、ジェンナのアプリは DesignMockRootView を
表示していた。

**学び**: 「production = MacOSRootView」と決めつけずに、handoff doc の
「既存サイドバーの Wikis 項目」が具体的にどちらを指すか確認すべきだった。
DesignMockRootView の Wikis placeholder の存在は探索フェーズで把握できて
いたので、もう一段「これがプロダクションで動いているか」を確認すれば
気付けた。

### 5. id-prefixed wikilink

ジェンナの vault は `rgn_0007_コルバ.md` のような命名規則で、
wikilink は `[[コルバ]]` (label のみ) で書かれていた。Obsidian の
本来の挙動 (filename 完全一致または shortest path) でも、私の初期実装
(filename prefix match) でも解決できなかった。

**学び**: 実 vault の命名規則は handoff doc に書かれていない。実 vault での
動作確認を A4 完了直後ではなく、もっと早い段階 (例えば A3 のインデクサ完了時)
にお願いすれば、resolver 設計に組み込めた。

## handoff doc の良かった点 / 改善できた点

### 良かった点

- **受け入れ基準が明確**: 9 項目すべて測定可能で、「動いているか」の判定に
  迷いがなかった
- **非破壊原則が一貫**: 「vault に書き込まない」が複数箇所で繰り返し
  強調されていて、実装時の判断軸が常にぶれなかった。WikiPageRepository の
  プロトコル設計時 (write メソッドを vault filesystem に向けない) や、
  テストの `testIndexingDoesNotModifyVault` の発想にも直接効いた
- **主要設計判断を Code に委ねず明文化**: vault index DB の配置、vault パスの
  永続化先、markdown ライブラリの選定、URL scheme 体系などが先決していた
  ので、実装時の方針迷子を回避できた
- **リスクと対応のセクション**: FSEvents の取りこぼしや規模制限など、
  「ここまでやれば OK」のラインが明示されていたので過剰実装を避けられた

### 改善できた点

- **アプリ起動先の明示**: 「production の sidebar」が MacOSRootView か
  DesignMockRootView か、handoff doc に書かれていれば一発で正しい場所に
  統合できた
- **App Sandbox の状況の明示**: Sandbox オフであること、Security-Scoped
  Bookmark が開発時 TCC 抑止には効かないこと、開発時の Full Disk Access
  運用などが先に共有されていれば、bookmark 修正に時間を取られなかった
- **vault 命名規則のサンプル**: ジェンナの vault が id-prefixed であることが
  事前に分かっていれば、resolver の設計を最初から正しい precedence で
  組めた
- **既存の auto-intake の存在の言及**: 「~/Documents 配下を監視している
  既存機能がある」と一言あれば、TCC prompt の切り分けが早かった
- **「サイドバー Wikis から見える」の解釈**: main window 内統合か別 window か
  両方あり得たので明示があるとよかった

## 工数感

- 純粋な A1〜A6 実装: 半セッション程度
- 中断された merge の復旧: 短時間
- TCC 関連の切り分け + 修正: 思ったより長い (数往復)
- 実 vault でのフィードバック対応 (resolver 拡張、フォルダ行クリック等):
  短時間ずつだが累積でそれなり

事前に handoff doc の改善点 4 つが分かっていれば、TCC 部分はかなり短縮
できた。逆に良かった点 4 つは、無かったら倍の時間がかかっていた可能性が
あるので、handoff doc 全体としては効率に大きく寄与した。

## 次の Phase への申し送り

- Phase B / Phase C は別セッションで着手
- A6 で実装した URL scheme 受信は Phase C の前提として動作確認済み
- vault UUID を Settings UI に表示する追加 (Phase C 用に必要) は
  Phase A スコープ外として保留
- 配布版の App Sandbox 化は将来 Phase で別途検討
- intake folder を Documents 外に置きたい場合の UI は既存
  (Archive Inspector の Drop folder セクション)、追加実装不要
