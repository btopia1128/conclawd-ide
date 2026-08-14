---
name: conclawd-release
description: >
  Conclawd（macOS IDE, /Users/riki/product/agent-terminal/conclawd-ide）の新バージョンをこのMacからリリースする。
  「Conclawdをリリースして」「新しいバージョンを出して」「v0.x.xを配布して」「dmgを更新して」「リリース作業やって」
  「LPのダウンロードを最新にして」など、Conclawdのリリース・配布・バージョンアップを指す依頼で発動する。
  バージョン決定→CHANGELOG作成→ビルド/署名/公証→R2アップロード（LPダウンロード更新）→GitHub Release→main push まで一括実行。
  単なるビルド確認やデバッグ実行では発動しない。
---

# Conclawd ローカルリリース手順

作業ディレクトリ: `/Users/riki/product/agent-terminal/conclawd-ide`

このMacに署名証明書（キーチェーン）・公証プロファイル（`conclawd-notary`）・wrangler OAuth が揃っている前提のローカルリリース。**リリース経路はこの手順のみ**（GitHub Actions のCIリリースは2026-08-14にセキュリティ方針で撤去済み。復活手順は conclawd-ide/docs/restore-ci-release.md）。

## 1. プリフライト

以下を確認。失敗したら中断してユーザーに報告:

- `git fetch origin && git status` — origin/main より遅れていたら pull。未コミット変更がある場合は一覧を見せ、リリースに含めるか確認する
- `security show-keychain-info login.keychain-db` — エラーならキーチェーンがロック中。ユーザーに `! security unlock-keychain ~/Library/Keychains/login.keychain-db` の実行を依頼
- `npx wrangler whoami` — R2 認証確認

## 2. バージョン決定（必ずユーザー確認）

- 現行: `project.yml` の `MARKETING_VERSION`
- `git log $(git describe --tags --abbrev=0)..HEAD --oneline` で前回リリースからの変更を把握
- ユーザーがバージョンを指定していなければ、変更内容から patch/minor を提案して AskUserQuestion で確認（バグ修正のみ→patch、機能追加→minor）

## 3. CHANGELOG 下書き（必ずユーザー確認）

- `CHANGELOG.md` に Keep a Changelog 形式・英語で `## [X.Y.Z] - YYYY-MM-DD` セクションを起草（### Added / Changed / Fixed / Removed）
- この内容がそのまま GitHub Release ノートと LP の changelog 表示になる。ユーザーに見せて OK をもらってから書き込む

## 4. ビルド〜配布物作成〜R2

```bash
# project.yml の MARKETING_VERSION を更新してから:
xcodegen generate
Scripts/release.sh   # build → sign → notarize(数分待つ) → dmg → R2アップロード
```

- 所要 ~7-10分。バックグラウンド実行で進捗を追う
- ここで失敗した場合は何もコミットしない。エラー内容を報告して終了
- release.sh 完了時点で LP のダウンロードボタン（R2 の `Conclawd.dmg`）は新版に切り替わる

## 5. コミット → tag → GitHub Release → push（この順序厳守）

```bash
git add project.yml CHANGELOG.md   # ＋リリースに含めると合意した変更
git commit -m "release: vX.Y.Z"
git tag vX.Y.Z
git push origin vX.Y.Z
awk '/^## \[X.Y.Z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md > /tmp/notes.md
gh release create vX.Y.Z "build/dist/Conclawd-X.Y.Z.dmg" --title vX.Y.Z --notes-file /tmp/notes.md
git push origin main
```

## 6. 検証と報告

- `gh release view vX.Y.Z` で dmg 添付を確認
- `curl -sI https://pub-3d16ad835aab4ec7804bf72e28fa2452.r2.dev/Conclawd.dmg` の Last-Modified が今であること
- LP changelog (https://conclawd.com/ja/changelog) は最大1時間の revalidate キャッシュで反映される旨をユーザーに伝える

## 失敗時のロールバック

- release.sh 失敗: 何も残らない。修正して再実行
- Release 作成後に push 失敗: push のみリトライ
- リリースを取り消したい: `gh release delete vX.Y.Z --yes` + `git push origin :refs/tags/vX.Y.Z`（R2 は前版の dmg を `wrangler r2 object put` で上げ直す）
