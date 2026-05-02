# Wiki Reader — 開発メモ

Phase A (Wiki Reader) 実装に関する開発時の注意事項。

## 開発環境での Full Disk Access

Xcode から `⌘R` でアプリを起動するたびに macOS の TCC ダイアログ
(「"Madini Archive.app" から、"書類" フォルダ内のファイルへのアクセス権を
求められています」)が大量に出る場合は、**Full Disk Access** にアプリを追加すれば
ダイアログを抑止できる。

### なぜ起きるか

- M.Archive は現在 **App Sandbox オフ** でビルドされている (project.yml で
  `com.apple.security.app-sandbox` が設定されていない、`ENABLE_HARDENED_RUNTIME: NO`)
- Sandbox オフだと、Security-Scoped Bookmark を resolve しても TCC は
  抑止されない (Apple 仕様。Sandbox なしの場合 bookmark の役割は path 解決のみ)
- 代わりに TCC は **code signing identity + path** で承認をキャッシュする方式になる
- Xcode の "Sign to Run Locally" ad-hoc 署名は build path や worktree が変わると
  別アプリと認識され、再 prompt される

### 設定方法

1. システム設定 → プライバシーとセキュリティ → **フルディスクアクセス**
2. 鍵アイコン解除
3. **+** → 以下のパスから `Madini Archive.app` を選択:
   ```
   <worktree>/build/Build/Products/Debug/Madini Archive.app
   ```
4. チェックマーク **ON**

複数の `Madini Archive` エントリが残っている場合は古いものを削除してから新規追加する。

### 配布版への影響

開発機の Full Disk Access は **配布版アプリには影響しない**(別 path / 別 signature
なので別アプリ扱い)。配布時は将来 App Sandbox を有効化して Security-Scoped
Bookmark で正規対応するのが望ましい。これは Phase A スコープ外。

## Wiki vault の登録メタデータ

- **登録**: `archive.db` の `wiki_vaults` テーブル (migration 4)
- **索引キャッシュ**: `~/Library/Application Support/Madini Archive/wiki_indexes/<vault_uuid>.db`
- **Security-Scoped Bookmark**: `wiki_vaults.bookmark_data` (BLOB) に保存。
  起動時に `WikiVaultAccessor` が resolve + scope 開始 + URL キャッシュ
- **Vault 自体**: 一切変更しない。`WikiRepository` プロトコルに write/delete
  メソッドが存在しないことが構造的保証

## デバッグで vault の登録を全消去したい

```bash
sqlite3 ~/Library/Application\ Support/Madini\ Archive/archive.db "DELETE FROM wiki_vaults;"
rm -rf ~/Library/Application\ Support/Madini\ Archive/wiki_indexes/
```

これでクリーン状態に戻る (`archive.db` の他のテーブルには影響しない)。

## 非破壊性の独立検証

Wiki vault のファイルが変更されていないか CLI で検証する:

```bash
VAULT="/path/to/your/vault"
shasum -a 256 "$VAULT"/**/*.md "$VAULT"/*.md 2>/dev/null | sort > /tmp/before.txt
# (アプリで vault 登録 + ブラウジング + 検索)
shasum -a 256 "$VAULT"/**/*.md "$VAULT"/*.md 2>/dev/null | sort > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt && echo "vault unchanged"
```

`testIndexingDoesNotModifyVault` および `testManualExternalVaultIsReadOnly`
が同じ保証を XCTest 側で行っている。

## URL scheme

`madini-archive://` 受信ハンドラは Phase A で実装済み。Phase C (Obsidian
プラグイン) からは:

```
madini-archive://wiki/<vault_id>/<relative_path>
```

を呼ぶことで M.Archive を起動して該当ページを開ける。

`vault_id` は `wiki_vaults.id` (UUID 文字列)。Obsidian プラグイン側で参照する
場合は、ユーザーが M.Archive Settings → Wiki Vaults で登録時に表示される
ID をコピーするか、Phase C で別途 vault 解決手段を設ける。
