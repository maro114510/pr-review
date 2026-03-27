#!/bin/bash
# レビュー出力内の `file:line` 引用を diff-index.json で機械的に検証する
# LLM を使用せず、スクリプトのみでファイル存在・行番号範囲を確認する
# Usage: check-citations.sh <レビュー出力ファイル> <ペルソナ名> <出力ディレクトリ>
#
# 結果は <出力ディレクトリ>/citation-check.json に追記（複数ペルソナ分が蓄積される）
# issues: ハルシネーション確定（削除推奨）
# warnings: 切り捨て等で検証不能（要注意）
set -euo pipefail

REVIEW_FILE="${1:?Usage: $0 <レビュー出力ファイル> <ペルソナ名> <出力ディレクトリ>}"
PERSONA="${2:?}"
OUT_DIR="${3:?}"

python3 - "$REVIEW_FILE" "$PERSONA" "$OUT_DIR" << 'PYTHON'
import sys, json, re, os

review_file, persona, out_dir = sys.argv[1:]
index_path   = os.path.join(out_dir, "diff-index.json")
out_path     = os.path.join(out_dir, "citation-check.json")

with open(review_file, encoding="utf-8") as f:
    review_text = f.read()

with open(index_path, encoding="utf-8") as f:
    diff_index = json.load(f)

files_info = diff_index.get("files", {})

# バッククォート囲み `file/path.ext:NNN` と裸の file/path.ext:NNN の両形式を検出
# 拡張子を含むパスのみ対象（単純な数値だけのケースを除外）
CITATION_RE_BT    = re.compile(r'`([^`\s]+\.[^`\s:]+):(\d+)`')
# URL パス内のホスト名 (例: https://pkg.go.dev/net/http.go:443) を誤検出しないよう
# 先行文字に / を追加。URL スキームの直後 (://) も除外される
CITATION_RE_PLAIN = re.compile(r'(?<![`\w/])([a-zA-Z][\w./\-]*\.[a-zA-Z]{1,10}):(\d+)(?![`\w/])')

issues   = []
warnings = []
checked  = 0

seen = set()
citations = []
for pat in (CITATION_RE_BT, CITATION_RE_PLAIN):
    for m in pat.finditer(review_text):
        key = (m.group(1), int(m.group(2)))
        if key not in seen:
            seen.add(key)
            citations.append(key)

for filename, line_num in citations:
    checked += 1

    # ファイルが PR の変更対象に含まれていない
    if filename not in files_info:
        issues.append({
            "reviewer": persona,
            "citation": f"{filename}:{line_num}",
            "type": "FILE_NOT_IN_PR",
            "detail": f"'{filename}' は PR の変更ファイルに含まれていません"
        })
        continue

    info = files_info[filename]

    # diff が切り捨てられていて検証不能
    if info.get("truncated") and not info.get("in_diff"):
        warnings.append({
            "reviewer": persona,
            "citation": f"{filename}:{line_num}",
            "type": "TRUNCATED",
            "detail": f"大規模 diff 切り捨てにより '{filename}' の検証不能"
        })
        continue

    # diff にファイルの変更が含まれていない（追加・変更なし）
    if not info.get("in_diff"):
        issues.append({
            "reviewer": persona,
            "citation": f"{filename}:{line_num}",
            "type": "FILE_NOT_IN_DIFF",
            "detail": f"'{filename}' は PR に含まれますが diff に変更がありません"
        })
        continue

    # 削除ファイルは行番号検証をスキップ
    if info.get("status") == "deleted":
        continue

    # 行番号が diff-raw.txt 内の当該ファイルのセクション範囲内にあるか確認
    # line_num は diff-raw.txt の絶対行番号（ファイル内行番号ではない）
    diff_start = info.get("diff_line_start")
    diff_end   = info.get("diff_line_end")
    if diff_start is not None and diff_end is not None:
        if not (diff_start <= line_num <= diff_end):
            issues.append({
                "reviewer": persona,
                "citation": f"{filename}:{line_num}",
                "type": "LINE_OUT_OF_DIFF_RANGE",
                "detail": (
                    f"行 {line_num} は {filename} の diff セクション範囲外です"
                    f"（diff-raw.txt 内の範囲: {diff_start}〜{diff_end}）"
                )
            })

# citation-check.json に追記（複数ペルソナの結果を蓄積）
if os.path.exists(out_path):
    with open(out_path, encoding="utf-8") as f:
        result = json.load(f)
else:
    result = {
        "issues":   [],
        "warnings": [],
        "stats": {"checked": 0, "invalid": 0, "warnings": 0}
    }

result["issues"].extend(issues)
result["warnings"].extend(warnings)
result["stats"]["checked"]  += checked
result["stats"]["invalid"]  += len(issues)
result["stats"]["warnings"] += len(warnings)

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

print(
    f"[{persona}] 検証完了: {checked} 件チェック, "
    f"{len(issues)} 件 NG (issues), {len(warnings)} 件 警告 (warnings)",
    file=sys.stderr
)
PYTHON
