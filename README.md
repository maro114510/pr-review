# pr-review

GitHub PR を 5 つの専門家視点（Principal Engineer / PM / Staff Engineer / 要求工学 / Security）から並列レビューし、引用ファーストのハルシネーション抑制設計で統合レポートを生成する Claude Code Skill。

## インストール

Claude Code の Plugin Marketplace 経由でインストールします。

```
/plugin marketplace add maro114510/pr-review
/plugin install pr-review@maro114510-pr-review
```

## 必要なもの

- [GitHub CLI (`gh`)](https://cli.github.com/) がインストール・認証済み
- Python 3（標準ライブラリのみ使用）

## 使い方

```
/pr-review 123
/pr-review https://github.com/owner/repo/pull/123
/pr-review   # 現在のブランチの PR を対象
```

自然言語でも起動します:

- "review this PR"
- "PRをレビューして"
- "コードレビューして"

## 出力

- **Executive Summary** — [must] 有無を明示した全体総評
- **[must] 修正必須項目** — 全視点集約テーブル
- **[ask] 確認必須項目** — 全視点集約テーブル
- 各専門家ペルソナの詳細レビュー（5セクション）
- **レビュー統計テーブル** — タグ別件数

## ハルシネーション防止設計

| 仕組み | 内容 |
|--------|------|
| データはファイル渡し | PR データをプロンプトに展開せず `/tmp/` に書き出し、サブエージェントは Read で参照 |
| 引用ファースト | 指摘は diff の該当行を verbatim 引用してからコメント。引用できない = 指摘不可 |
| URL 事前検証 | `build-url-library.sh` が HTTP 検証済み URL のみを `url-library.json` に格納。リスト外 URL は使用禁止 |
| 機械検証 | `check-citations.sh`（Python）が file:line 引用の正確性を検証し、問題ある指摘を除外 |

## ライセンス

MIT
