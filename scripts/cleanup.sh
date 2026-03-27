#!/bin/bash
# PR レビュー完了後に一時ファイルを削除する
# Usage: cleanup.sh <出力ディレクトリ>
set -euo pipefail

OUT_DIR="${1:?Usage: $0 <出力ディレクトリ>}"

if [ -d "$OUT_DIR" ]; then
  rm -rf "$OUT_DIR"
  echo "クリーンアップ完了: $OUT_DIR" >&2
else
  echo "スキップ（既に削除済み）: $OUT_DIR" >&2
fi
