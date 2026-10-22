#!/usr/bin/env bash
# Verify that every ref in a release manifest is present in the target remote
# (develop by default, products for --no-promote) with at least one binary.
# The manifest is written last by ci-products-release.sh, so its presence is
# the release pointer for consumers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/ci-lib.sh
source "$ROOT_DIR/scripts/ci-lib.sh"

ci_require_conan
ci_require_python

DEVELOP_REMOTE="${DEVELOP_REMOTE:-develop}"
VERIFY_REMOTE="${CI_VERIFY_REMOTE:-$DEVELOP_REMOTE}"
manifest="${1:-$ROOT_DIR/lockfiles/ci/release-manifest.json}"

if [ ! -s "$manifest" ]; then
    echo "ERROR: release manifest not found or empty: $manifest" >&2
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$manifest" > "$tmp_dir/refs.txt" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
for ref in data.get("refs", []):
    print(ref)
PY

if [ ! -s "$tmp_dir/refs.txt" ]; then
    echo "ERROR: manifest contains no refs" >&2
    exit 1
fi

while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    out="$tmp_dir/$(echo "$ref" | tr '/:' '__').json"
    conan list "$ref:*#*" -r "$VERIFY_REMOTE" --format=json --out-file "$out"
    if [ -z "$(ci_package_ids "$out")" ]; then
        echo "ERROR: ${ref} has no packages in ${VERIFY_REMOTE}" >&2
        exit 1
    fi
    echo "OK ${ref} in ${VERIFY_REMOTE}"
done < "$tmp_dir/refs.txt"

echo "Release manifest verified: $manifest"
