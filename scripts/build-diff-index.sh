#!/bin/bash
# diff-raw.txt と file-list.json から diff-index.json を生成する
# 変更ファイルごとに「どの行番号が変更されたか」を記録し、
# 後段の check-citations.sh が LLM なしで file:line 引用を機械的に検証できるようにする
# Usage: build-diff-index.sh <出力ディレクトリ>
set -euo pipefail

OUT_DIR="${1:?Usage: $0 <出力ディレクトリ>}"

echo "=== diff インデックス構築中 ===" >&2

python3 - "$OUT_DIR" << 'PYTHON'
import sys, json, re, os

out_dir = sys.argv[1]
diff_file  = os.path.join(out_dir, "diff-raw.txt")
file_list_path = os.path.join(out_dir, "file-list.json")
out_path   = os.path.join(out_dir, "diff-index.json")

# GitHub API のファイルリストを権威あるリストとして使用
with open(file_list_path) as f:
    api_files = json.load(f)

diff_index = {"files": {}}
for f in api_files:
    diff_index["files"][f["filename"]] = {
        "status": f["status"],   # added / modified / deleted / renamed / copied
        "in_diff": False,        # diff-raw.txt に当該ファイルの diff が含まれているか
        "truncated": False,      # 大規模diff 切り捨てにより diff が不完全か
        "changed_ranges": []     # [[new_file_start, new_file_end], ...]
    }

# diff-raw.txt をパースして hunk ごとの変更行範囲を抽出
# hunk header: @@ -old_start[,old_count] +new_start[,new_count] @@
# new_start / new_count は新ファイルでの行番号ベース
current_file = None
with open(diff_file, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")

        m = re.match(r"^diff --git a/.+ b/(.+)$", line)
        if m:
            current_file = m.group(1)
            if current_file not in diff_index["files"]:
                # GitHub API リストにないファイル（リネーム等で稀に発生）
                diff_index["files"][current_file] = {
                    "status": "unknown",
                    "in_diff": True,
                    "truncated": False,
                    "changed_ranges": []
                }
            diff_index["files"][current_file]["in_diff"] = True
            continue

        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
        if m and current_file:
            new_start = int(m.group(1))
            # カウントが省略されている場合は 1 行
            new_count = int(m.group(2)) if m.group(2) is not None else 1
            if new_count > 0:
                diff_index["files"][current_file]["changed_ranges"].append(
                    [new_start, new_start + new_count - 1]
                )
            continue

# diff が切り捨てられた場合、diff に含まれないファイルを truncated とマーク
if os.path.exists(os.path.join(out_dir, ".truncated")):
    for fname, info in diff_index["files"].items():
        if not info["in_diff"]:
            info["truncated"] = True

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(diff_index, f, indent=2, ensure_ascii=False)

total     = len(diff_index["files"])
in_diff   = sum(1 for v in diff_index["files"].values() if v["in_diff"])
truncated = sum(1 for v in diff_index["files"].values() if v["truncated"])
print(f"diff-index.json 生成完了: 全 {total} ファイル ({in_diff} in diff, {truncated} truncated)", file=sys.stderr)
PYTHON
