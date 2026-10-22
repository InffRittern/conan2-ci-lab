#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v conan >/dev/null 2>&1; then
    echo "ERROR: conan not found in PATH. Install it with: uv tool install conan" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required to parse conan list JSON." >&2
    exit 1
fi

pattern="${1:-}"
src_remote="${2:-}"
dst_remote="${3:-}"
if [ -z "$pattern" ] || [ -z "$src_remote" ] || [ -z "$dst_remote" ]; then
    echo "Usage: $0 <ref-pattern> <src-remote> <dst-remote>" >&2
    exit 2
fi

case "$pattern" in
    *:*) ;;
    *) pattern="$pattern:*" ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "=== Listing ${pattern} in ${src_remote} ==="
conan list "$pattern" -r "$src_remote" --format=json --out-file "$tmp_dir/list.json"

python3 - "$tmp_dir/list.json" > "$tmp_dir/refs.txt" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

refs = set()


def walk(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(key, str) and "/" in key and not key.startswith("revisions"):
                refs.add(key.split("#", 1)[0])
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)


walk(data)
for ref in sorted(refs):
    print(ref)
PY

if [ ! -s "$tmp_dir/refs.txt" ]; then
    echo "ERROR: no references matched ${pattern} in ${src_remote}" >&2
    exit 1
fi

while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    echo "=== Promoting ${ref} -> ${dst_remote} ==="

    conan download "${ref}:*" -r "$src_remote"
    conan upload "${ref}:*" -r "$dst_remote" -c
done < "$tmp_dir/refs.txt"

echo "=== Verifying in ${dst_remote} ==="
conan list "$pattern" -r "$dst_remote"
