#!/bin/bash
# PR の変更ファイルを分析し、レビュー分類（docs / implementation）とエージェント一覧を出力する
# Usage: classify-pr.sh <出力ディレクトリ>
# 出力: <出力ディレクトリ>/classification.json
set -euo pipefail

OUT_DIR="${1:?Usage: $0 <出力ディレクトリ>}"

echo "=== PR 分類中 ===" >&2

python3 - "$OUT_DIR" << 'PYTHON'
import json
import os
import re
import sys

out_dir = sys.argv[1]
file_list_path = os.path.join(out_dir, "file-list.json")
out_path = os.path.join(out_dir, "classification.json")

with open(file_list_path, encoding="utf-8") as f:
    files = json.load(f)

# ドキュメント専用ファイルと判定するパターン
DOC_PATTERN = re.compile(
    r"(^|\/)docs?/"
    r"|^(README|CHANGELOG|LICENSE|CONTRIBUTING)(\..+)?$"
    r"|\.(md|txt|rst|adoc)$",
    re.IGNORECASE,
)

filenames = [f.get("filename", "") for f in files if isinstance(f, dict)]
total = len(filenames)
doc_count = sum(1 for fn in filenames if DOC_PATTERN.search(fn))

# 全変更ファイルがドキュメント系の場合のみ docs 分類
if total > 0 and doc_count == total:
    pr_type = "docs"
    agents = ["pm", "req", "security"]
else:
    pr_type = "implementation"
    agents = ["pe", "pm", "staff", "req", "security"]

result = {
    "type": pr_type,
    "agents": agents,
    "stats": {
        "total_files": total,
        "doc_files": doc_count,
    },
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
    f.write("\n")

label = ", ".join(a.upper() for a in agents)
print(
    f"  分類: {pr_type}（{len(agents)} 視点: {label}）",
    file=sys.stderr,
)
PYTHON

echo "完了: ${OUT_DIR}/classification.json" >&2
