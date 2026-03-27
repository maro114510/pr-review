#!/bin/bash
# PR データを GitHub API で収集し、構造化ファイルとして出力ディレクトリに格納する
# Usage: fetch-pr-data.sh <PR番号> <出力ディレクトリ>
set -euo pipefail

PR_NUMBER="${1:?Usage: $0 <PR番号> <出力ディレクトリ>}"
OUT_DIR="${2:?}"

mkdir -p "$OUT_DIR"

echo "=== PR #${PR_NUMBER} データ収集中 ===" >&2

# リポジトリ名取得（GitHub API パス構築用）
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# 1. PR メタ情報
echo "[1/4] PR メタ情報取得..." >&2
gh pr view "$PR_NUMBER" \
  --json number,title,body,author,baseRefName,headRefName,labels,assignees,reviewRequests,state,createdAt,updatedAt \
  > "$OUT_DIR/pr-meta.json"

# 2. 変更ファイル一覧（GitHub API で取得。gh pr diff より確実・ページネーション対応）
echo "[2/4] 変更ファイル一覧取得..." >&2
gh api "repos/$REPO/pulls/$PR_NUMBER/files" --paginate \
  > "$OUT_DIR/file-list.json"

FILE_COUNT=$(jq 'length' "$OUT_DIR/file-list.json")
echo "  変更ファイル: ${FILE_COUNT} 件" >&2

# 3. raw diff（行数制限付き）
echo "[3/4] diff 取得..." >&2
DIFF_CONTENT=$(gh pr diff "$PR_NUMBER" 2>/dev/null || echo "")
DIFF_LINES=$(echo "$DIFF_CONTENT" | wc -l | tr -d ' ')

if [ "$DIFF_LINES" -gt 8000 ]; then
  echo "$DIFF_CONTENT" | head -8000 > "$OUT_DIR/diff-raw.txt"
  echo "" >> "$OUT_DIR/diff-raw.txt"
  echo "--- 以降省略（大規模差分: ${DIFF_LINES}行 → 8000行で切り捨て）---" >> "$OUT_DIR/diff-raw.txt"
  touch "$OUT_DIR/.truncated"
  echo "  警告: 差分 ${DIFF_LINES} 行 → 8000 行で切り捨て" >&2
else
  echo "$DIFF_CONTENT" > "$OUT_DIR/diff-raw.txt"
  echo "  差分: ${DIFF_LINES} 行" >&2
fi

# 4. 既存コメント（重複指摘防止用）
echo "[4/4] 既存コメント取得..." >&2
{
  echo "=== レビューコメント（本文レベル）==="
  gh pr view "$PR_NUMBER" --json reviews \
    --jq '.reviews[] | "[\(.author.login)] \(.state): \(.body)"' 2>/dev/null || echo "(なし)"

  echo ""
  echo "=== インラインコメント（ファイル:行レベル）==="
  gh pr view "$PR_NUMBER" --json reviewThreads \
    --jq '.reviewThreads[] | .comments[] | "[\(.author.login)] \(.path):\(.line // .originalLine // "?"): \(.body)"' 2>/dev/null || echo "(なし)"

  echo ""
  echo "=== PRスレッドコメント ==="
  gh pr view "$PR_NUMBER" --json comments \
    --jq '.comments[] | "[\(.author.login)]: \(.body)"' 2>/dev/null || echo "(なし)"
} > "$OUT_DIR/comments.txt"

echo "完了: $OUT_DIR" >&2
