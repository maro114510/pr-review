#!/bin/bash
# 変更ファイルから技術スタックを検出し、事前 HTTP 検証済みの URL ライブラリを生成する
# レビュアーはこのファイルのURLのみ引用する（記憶由来の URL 生成を排除）
# Usage: build-url-library.sh <出力ディレクトリ>
set -euo pipefail

OUT_DIR="${1:?Usage: $0 <出力ディレクトリ>}"

echo "=== URL ライブラリ構築中 ===" >&2

python3 - "$OUT_DIR" << 'PYTHON'
import sys, json, re, os
import urllib.request, urllib.error

out_dir    = sys.argv[1]
file_list_path = os.path.join(out_dir, "file-list.json")
out_path   = os.path.join(out_dir, "url-library.json")

# プリセット URL ライブラリ
# - スタックごとに主要な公式ドキュメント・標準を列挙
# - 記憶ではなくこのリストから選ぶことでハレーションを排除
PRESET = {
    "security": {
        "OWASP Top 10 (2021)": "https://owasp.org/Top10/",
        "OWASP Injection (A03)": "https://owasp.org/Top10/A03_2021-Injection/",
        "OWASP Cryptographic Failures (A02)": "https://owasp.org/Top10/A02_2021-Cryptographic_Failures/",
        "OWASP Authentication Failures (A07)": "https://owasp.org/Top10/A07_2021-Identification_and_Authentication_Failures/",
        "OWASP Cheat Sheet Series": "https://cheatsheetseries.owasp.org/",
        "CWE Top 25": "https://cwe.mitre.org/top25/",
        "NIST Cybersecurity Framework": "https://www.nist.gov/cyberframework",
    },
    "go": {
        "Effective Go": "https://go.dev/doc/effective_go",
        "Go Error Handling": "https://go.dev/blog/error-handling-and-go",
        "Go context package": "https://pkg.go.dev/context",
        "Google Go Style Decisions": "https://google.github.io/styleguide/go/decisions",
        "Go testing package": "https://pkg.go.dev/testing",
    },
    "typescript": {
        "TypeScript Handbook": "https://www.typescriptlang.org/docs/handbook/intro.html",
        "React Reference": "https://react.dev/reference/react",
        "Airbnb JavaScript Style Guide": "https://github.com/airbnb/javascript",
        "Node.js Best Practices": "https://github.com/goldbergyoni/nodebestpractices",
    },
    "swift": {
        "Swift API Design Guidelines": "https://www.swift.org/documentation/api-design-guidelines/",
        "Swift Concurrency": "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/",
        "Swift Error Handling": "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/",
    },
    "kotlin": {
        "Kotlin Coding Conventions": "https://kotlinlang.org/docs/coding-conventions.html",
        "Android App Architecture": "https://developer.android.com/topic/architecture",
        "Kotlin Coroutines Guide": "https://kotlinlang.org/docs/coroutines-guide.html",
    },
    "python": {
        "PEP 8 Style Guide": "https://peps.python.org/pep-0008/",
        "Python typing": "https://docs.python.org/3/library/typing.html",
        "Python logging": "https://docs.python.org/3/howto/logging.html",
    },
    "grpc": {
        "gRPC Best Practices": "https://grpc.io/docs/guides/",
        "Protocol Buffers Language Guide (proto3)": "https://protobuf.dev/programming-guides/proto3/",
        "gRPC Error Handling": "https://grpc.io/docs/guides/error/",
    },
    "sql": {
        "SQL Injection Prevention (OWASP)": "https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html",
        "Database Security (OWASP)": "https://cheatsheetseries.owasp.org/cheatsheets/Database_Security_Cheat_Sheet.html",
    },
    "docker": {
        "Dockerfile Best Practices": "https://docs.docker.com/build/building/best-practices/",
        "Docker Security": "https://docs.docker.com/engine/security/",
    },
}

# 技術スタック検出（ファイル拡張子・パターンから判定）
def detect_stacks(filenames):
    stacks = {"security"}  # セキュリティ観点は常に含める
    for f in filenames:
        if re.search(r'\.go$', f):                         stacks.add("go")
        if re.search(r'\.(ts|tsx|js|jsx)$', f):            stacks.add("typescript")
        if re.search(r'\.swift$', f):                      stacks.add("swift")
        if re.search(r'\.kt(s)?$', f):                     stacks.add("kotlin")
        if re.search(r'\.py$', f):                         stacks.add("python")
        if re.search(r'\.proto$', f):                      stacks.add("grpc")
        if re.search(r'\.(sql)$|migration', f):            stacks.add("sql")
        if re.search(r'Dockerfile|docker-compose', f):     stacks.add("docker")
    return stacks

# URL 検証（HEAD → GET フォールバック、タイムアウト 5 秒）
def validate_url(url, timeout=5):
    headers = {"User-Agent": "Mozilla/5.0"}
    for method in ("HEAD", "GET"):
        try:
            req = urllib.request.Request(url, method=method, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status in (200, 301, 302)
        except Exception:
            continue
    return False

# メイン処理
with open(file_list_path) as f:
    api_files = json.load(f)

filenames = [f["filename"] for f in api_files]
stacks = detect_stacks(filenames)
print(f"検出スタック: {', '.join(sorted(stacks))}", file=sys.stderr)

result = {}
total_urls = 0
failed_urls = 0

for stack in sorted(stacks):
    if stack not in PRESET:
        continue
    validated = {}
    for label, url in PRESET[stack].items():
        total_urls += 1
        print(f"  [{stack}] 検証中: {url}", file=sys.stderr)
        if validate_url(url):
            validated[label] = url
            print(f"    ✓", file=sys.stderr)
        else:
            failed_urls += 1
            print(f"    ✗ 除外（到達不可）", file=sys.stderr)
    if validated:
        result[stack] = validated

# ネットワーク不通フォールバック: 全 URL が失敗した場合はプリセット全採用
if total_urls > 0 and failed_urls == total_urls:
    print("警告: 全 URL の検証に失敗しました（ネットワーク不通の可能性）。プリセット URL を検証なしで使用します。", file=sys.stderr)
    result = {stack: dict(PRESET[stack]) for stack in sorted(stacks) if stack in PRESET}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

total = sum(len(v) for v in result.values())
print(f"URL ライブラリ生成完了: {total} 件の有効 URL → {out_path}", file=sys.stderr)
PYTHON
