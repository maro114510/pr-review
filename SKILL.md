---
name: pr-review
description: >
  Review GitHub PRs from 5 specialist perspectives (Principal Engineer, PM, Staff Engineer,
  Requirements Engineering, Security) in parallel using subagents, producing a structured
  Markdown report with hallucination-resistant citations.
  Use this skill whenever the user asks to review a PR, do a code review, look at a pull
  request, or check changes. Trigger on: "review this PR", "レビューして", "PRを見て", "コードレビュー".
allowed-tools: Bash, Read, Agent, WebFetch
argument-hint: "<PR# or URL>"
---

# pr-review — 5視点並列PRレビュー

GitHub PRを5つの専門家ペルソナが並列でレビューし、スクリプトによるファクトチェックを経た統合レポートを生成する。

## ハレーション防止の設計原則

- **データはファイルで渡す**: PR データをプロンプト文字列に展開しない。スクリプトがファイルに書き出し、サブエージェントは Read ツールで参照する
- **引用ファースト**: 指摘は diff の該当行を必ず quote してからコメントする。引用できない = diff に存在しない = 指摘してはいけない
- **URL は事前検証済みリストのみ**: 記憶から URL を生成しない。build-url-library.sh が HTTP 検証済みの URL のみを url-library.json に格納し、レビュアーはそこから引用する
- **機械検証を優先**: file:line 引用の正確性は LLM ではなく check-citations.sh（Python スクリプト）が検証する

---

## ステップ 1: PR 特定

`$ARGUMENTS` を解析する:

- 数値のみ（例: `123`）→ そのままPR番号として使用
- GitHub URL（`/pull/123` を含む）→ URLから番号を抽出
- 引数なし → `gh pr view --json number` で現在のブランチのPRを取得

PR番号が特定できない場合はユーザーに確認して停止する。

以降のステップで使用する変数を設定する:
```
PR_NUMBER = <特定したPR番号>
DATA_DIR  = /tmp/pr-review-<PR_NUMBER>
SCRIPTS   = ${CLAUDE_SKILL_DIR}/scripts
```

---

## ステップ 2: スクリプトによる PR データ収集

以下を順番に実行する:

```bash
# PR データ一括収集（pr-meta.json / file-list.json / diff-raw.txt / comments.txt）
bash <SCRIPTS>/fetch-pr-data.sh <PR_NUMBER> <DATA_DIR>

# diff-index.json 生成（file:line 検証の基礎データ）
bash <SCRIPTS>/build-diff-index.sh <DATA_DIR>

# url-library.json 生成（技術スタック検出 + HTTP 事前検証）
bash <SCRIPTS>/build-url-library.sh <DATA_DIR>
```

完了後、`<DATA_DIR>/` に以下のファイルが存在することを確認する:
- `pr-meta.json` — PR 基本情報
- `file-list.json` — 変更ファイル一覧（GitHub API 取得）
- `diff-raw.txt` — 差分テキスト（8000行上限）
- `comments.txt` — 既存レビューコメント
- `diff-index.json` — ファイル別変更行範囲マップ
- `url-library.json` — 検証済み参照 URL

---

## ステップ 3: レビュアーペルソナ読み込み

各サブエージェントが自身のペルソナファイルを独立して Read する設計のため、親エージェントはこのステップでペルソナを読み込まない。ステップ4のプロンプトテンプレートに従ってサブエージェントに読み込みを委譲する。

---

## ステップ 4: 5サブエージェント完全並列起動

**以下の5つのAgentツール呼び出しを同一ターンで同時に発行する。** 順番に実行してはならない。

各サブエージェントに渡すプロンプトは次のテンプレートで構築する（`<DATA_DIR>` と `<PERSONA_FILE>` を実際の値に置換すること。`<PERSONA_FILE>` は各ペルソナのファイルパス: `${CLAUDE_SKILL_DIR}/references/pe.md` / `pm.md` / `staff.md` / `req.md` / `security.md` のいずれか）:

---
### サブエージェント共通プロンプトテンプレート

```
あなたは <PERSONA_FILE> に定義されたレビュアーです。まず最初にこのファイルを Read ツールで読み込んでください。

=== データファイルの読み込み ===
以下のファイルを Read ツールで読み込んでください:
1. <DATA_DIR>/pr-meta.json      — PR 基本情報
2. <DATA_DIR>/diff-raw.txt      — 差分テキスト
3. <DATA_DIR>/comments.txt      — 既存レビューコメント（重複防止に必須）
4. <DATA_DIR>/url-library.json  — 使用可能な参照 URL（このリスト以外の URL は使用禁止）

=== 既存コメントの確認 ===
comments.txt を確認し、以下のルールに従うこと:
1. 既に指摘されている内容は重複して指摘しない
2. 既存指摘を補完する場合は「既存コメント（@著者名）への追記:」と明示する
3. 解決済み (resolved) スレッドの内容は指摘しない

=== レビュアー指示 ===
<PERSONA_FILE> を Read ツールで読み込み、その全内容に従ってレビューすること。

=== 出力要件 ===

## メタ情報タグ
| タグ | 期待対応 | 説明 |
|------|----------|------|
| [ask] | 回答必須 | 確認が必要な事項 |
| [must] | 修正必須 | これがなければApprove不可 |
| [imo] | 修正任意 | 対応なくてもApprove可 |
| [nits] | 修正任意 | 細かい指摘 |
| [next] | 修正不要 | 今後の改善点 |
| [good] | — | 良い点 |
| [suggestion] | — | 根拠なしの提案（url-library.json に適切なURLがない場合） |

## 指摘フォーマット（厳守）
各指摘は必ず以下の順序で記述すること:

- **[タグ] `ファイル名:N`**: 問題の説明
  - 引用: `diff-raw.txt の N 行目のコード`
  - 問題: （何が・なぜ問題か）
  - 改善案: （具体的なコードまたは手順）
  - 参考: [ラベル](url-library.json に記載のURL)

**行番号 N のルール（厳守）**:
- N は **diff-raw.txt を Read した際の行番号**（diff-raw.txt の先頭が 1）
- ファイル内行番号（ファイル単体を開いたときの行番号）ではない
- Read ツールが返す行番号プレフィックス（例: `  42→+some code`）の数字をそのまま使うこと
- 引用するコードが diff-raw.txt の N 行目に verbatim で存在することを必ず確認すること
- `+` で始まる追加行のみを引用対象とすること（`-` 行・コンテキスト行は引用しない）
- diff-raw.txt に該当コードが見当たらない場合は、その指摘を行ってはならない
- url-library.json にない URL は使用せず、[suggestion] タグに格下げして「url-library 外のため参照なし」と明記すること

## 出力フォーマット
### [ペルソナ名] レビュー

#### 総評
（2〜4文）

#### 指摘事項
（深刻なものから順に箇条書き）

#### 良い点
（[good] タグで評価できる点）

=== 結果の保存 ===
上記レビュー結果の全文を Write ツールで `<DATA_DIR>/review-<PERSONA_NAME>.txt` にプレーンテキストとして保存すること。
（`<DATA_DIR>` と `<PERSONA_NAME>` は pe / pm / staff / req / security のいずれかに置換済みであること）
```
---

各ペルソナファイルの内容をそのままプロンプトに埋め込む。

> **重要**: 5つのAgentツール呼び出しは必ず同時に発行すること。

---

## ステップ 5: 全エージェント完了待機・結果確認

5つのエージェントがすべて完了するまで待機する。各エージェントは Write ツールで結果を自動保存済みのため、以下のファイルが存在することを確認する:

```bash
ls <DATA_DIR>/review-pe.txt \
   <DATA_DIR>/review-pm.txt \
   <DATA_DIR>/review-staff.txt \
   <DATA_DIR>/review-req.txt \
   <DATA_DIR>/review-security.txt
```

いずれかのファイルが欠けている場合はユーザーにエラーを報告し、処理を停止する。

---

## ステップ 6: スクリプトによる引用検証

5つのレビュー結果に対して `check-citations.sh` を実行する:

```bash
bash <SCRIPTS>/check-citations.sh <DATA_DIR>/review-pe.txt     pe       <DATA_DIR>
bash <SCRIPTS>/check-citations.sh <DATA_DIR>/review-pm.txt     pm       <DATA_DIR>
bash <SCRIPTS>/check-citations.sh <DATA_DIR>/review-staff.txt  staff    <DATA_DIR>
bash <SCRIPTS>/check-citations.sh <DATA_DIR>/review-req.txt    req      <DATA_DIR>
bash <SCRIPTS>/check-citations.sh <DATA_DIR>/review-security.txt security <DATA_DIR>
```

`<DATA_DIR>/citation-check.json` を Read ツールで読み込み、結果を確認する。

**適用ルール:**
- `issues` に含まれる指摘（`FILE_NOT_IN_PR` / `FILE_NOT_IN_DIFF`）→ 統合レポートから除外
- `warnings` に含まれる指摘（`LINE_OUT_OF_CHANGED_RANGE` / `TRUNCATED`）→ 末尾に「※ 検証注意」を付記

---

## ステップ 7: 一次フィルタリング（妥当性確認）

5つの結果とcitation-check.json を俯瞰し、以下の観点で調整する:

**除外すべき指摘（ノイズ）:**
- 汎用的すぎて具体性がない（例: 「セキュリティを考慮してください」のみ）
- すでに他の視点で同一内容が指摘されており重複と判断できるもの

**格上げ検討 ([imo] → [must]):**
- 複数の視点で共通して重大と評価された指摘

**格下げ検討 ([must] → [imo]):**
- PRの説明で既に対処済みと明記されているもの

---

## ステップ 8: 統合レポート生成・出力

ステップ 6・7 の結果を適用してから、以下の構造でMarkdownレポートを生成し端末に出力する:

```markdown
# PR Review Report

## #<番号> <タイトル>
**著者**: <author> | **ベース**: <baseRefName> ← <headRefName> | **状態**: <state>

---

## Executive Summary

> （5視点全体を踏まえた総評。[must]が存在するかどうかを明示する）

---

## [must] 修正必須項目（全視点集約）

> ※ このセクションの項目がすべて解消されるまでApproveを推奨しない

| # | 視点 | ファイル:行 | 概要 | 参照 |
|---|------|------------|------|------|

---

## [ask] 確認必須項目（全視点集約）

| # | 視点 | 概要 |
|---|------|------|

---

## Principal Engineer レビュー
<RESULT_PE の内容>

---

## PM レビュー
<RESULT_PM の内容>

---

## Staff Engineer レビュー
<RESULT_STAFF の内容>

---

## Requirements Engineering レビュー
<RESULT_REQ の内容>

---

## Security レビュー
<RESULT_SEC の内容>

---

## [good] 良い点（全視点集約）

---

## レビュー統計

| 視点 | [must] | [ask] | [imo] | [nits] | [next] | [good] | [suggestion] |
|------|--------|-------|-------|--------|--------|--------|--------------|
| PE   | N      | N     | N     | N      | N      | N      | N            |
| PM   | N      | N     | N     | N      | N      | N      | N            |
| SE   | N      | N     | N     | N      | N      | N      | N            |
| REQ  | N      | N     | N     | N      | N      | N      | N            |
| SEC  | N      | N     | N     | N      | N      | N      | N            |
| **計** | **N** | **N** | **N** | **N** | **N** | **N** | **N**        |

> スクリプト検証により除外: N件 / 検証注意: N件
```

---

## ステップ 9: クリーンアップ（任意）

レポート出力後、削除前にユーザーに確認する:

「一時ファイル（`<DATA_DIR>`）を削除しますか？削除しない場合、レビューデータは保持されます。」

削除を希望する場合のみ実行する:

```bash
bash <SCRIPTS>/cleanup.sh <DATA_DIR>
```
