# CIリリース（フォールバック）を復活させる手順

現在のリリースはローカル実行のみ（`Scripts/release.sh` / Claude Codeの `conclawd-release` skill）。
GitHub Actions での自動リリースは 2026-08-14 にセキュリティ観点（公開リポジトリに署名証明書等の
secrets を常設しない方針）で撤去した。復活させる場合は、secrets を Environment 保護付きで
再登録する以下の「プランB」構成にすること。

## 1. ワークフローを履歴から復元

```bash
git checkout 6a97d71 -- .github/workflows/release.yml
```

（`6a97d71` = "ci: add automated release pipeline on main push"。撤去コミット以前ならどれでも可）

## 2. Environment `release` を作成し承認ゲートを設定

GitHub: リポジトリ → Settings → Environments → New environment → `release`

- **Required reviewers** に自分を追加（← これが本体。releaseジョブは secrets に触る前に承認待ちで停止する）
- 必要なら Deployment branches を `main` のみに制限

## 3. ワークフローの release ジョブに environment を指定

```yaml
  release:
    needs: check-version
    if: needs.check-version.outputs.is-new == 'true'
    runs-on: macos-26
    environment: release        # ← 追加
```

あわせて `actions/checkout@v4` をコミットSHAピン留めにするとなお良い。

## 4. secrets を Environment secrets として再登録（7つ）

リポジトリ直下ではなく `--env release` を付けて登録する:

```bash
REPO=rinte-ringoteto/conclawd-ide

# 署名証明書: キーチェーンアクセス → 自分の証明書 →
# 「Developer ID Application: Stellaps Inc. (8LG94A3CX7)」を右クリック → 書き出す(.p12, パスワード付き)
base64 -i ~/Desktop/cert.p12 | gh secret set MACOS_CERT_P12 -R $REPO --env release
gh secret set MACOS_CERT_PASSWORD -R $REPO --env release   # p12のパスワード
rm ~/Desktop/cert.p12

# 公証: App用パスワードは https://account.apple.com → サインインとセキュリティ → App用パスワード で新規発行
gh secret set APPLE_ID -R $REPO --env release -b "riki.hoshino@stellaps.co.jp"
gh secret set APPLE_APP_PASSWORD -R $REPO --env release
gh secret set APPLE_TEAM_ID -R $REPO --env release -b "8LG94A3CX7"

# R2: Cloudflareダッシュボード → R2 → Manage R2 API Tokens → Create Account API Token
#     (Object Read & Write / バケット conclawd-downloads 限定)
gh secret set CLOUDFLARE_API_TOKEN -R $REPO --env release
gh secret set CLOUDFLARE_ACCOUNT_ID -R $REPO --env release -b "bae47c1309b26863e62cb03f9373237d"
```

## 5. 動作確認

```bash
git add .github/workflows/release.yml && git commit -m "ci: restore release pipeline with environment protection" && git push
gh workflow run Release -R rinte-ringoteto/conclawd-ide   # バージョン未更新なら check-version でスキップされれば正常
```

以後、バージョンを上げて main に push すると Actions が起動し、**承認待ちの通知**が来る。
Actions ページで Approve すると リリース（ビルド→署名→公証→R2→GitHub Release）が実行される。

## 運用メモ

- ローカルリリース（skill）と共存可能: skill は GitHub Release を作ってから main を push するため、
  CI は check-version で「リリース済み」と判定してスキップする
- Apple ID 本体のパスワードを変更すると App用パスワードは全失効 → 再発行して再登録
- 撤去時に Cloudflare 側のトークン `conclawd-ci-release` も失効させている場合は新規作成が必要
