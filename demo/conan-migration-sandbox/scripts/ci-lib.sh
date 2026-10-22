#!/usr/bin/env bash
# Shared helpers for the staged CI pipeline.  Source this file; do not run it.

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ci_require_conan() {
    if ! command -v conan >/dev/null 2>&1; then
        echo "ERROR: conan not found in PATH. Install it with: uv tool install conan" >&2
        exit 1
    fi
}

ci_require_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 is required to parse Conan JSON." >&2
        exit 1
    fi
}

# Map a package name to the environment variable consumed by set_version().
ci_version_env_for() {
    case "$1" in
        ap-base) echo "AP_BASE_VERSION" ;;
        ap-utils) echo "AP_UTILS_VERSION" ;;
        ap-gfx) echo "AP_GFX_VERSION" ;;
        ap-headers) echo "AP_HEADERS_VERSION" ;;
        ap-texture) echo "AP_TEXTURE_VERSION" ;;
        ap-box) echo "AP_BOX_VERSION" ;;
        ap-sdk) echo "AP_SDK_VERSION" ;;
        ap-product-a) echo "AP_PRODUCT_A_VERSION" ;;
        ap-product-b) echo "AP_PRODUCT_B_VERSION" ;;
        *) echo "" ;;
    esac
}

# Map a package name to its source directory in this sandbox.
ci_path_for() {
    case "$1" in
        ap-base) echo "$CI_ROOT/libs/ap-base" ;;
        ap-utils) echo "$CI_ROOT/libs/ap-utils" ;;
        ap-gfx) echo "$CI_ROOT/libs/ap-gfx" ;;
        ap-headers) echo "$CI_ROOT/libs/ap-headers" ;;
        ap-texture) echo "$CI_ROOT/libs/ap-texture" ;;
        ap-box) echo "$CI_ROOT/libs/ap-box" ;;
        ap-sdk) echo "$CI_ROOT/libs/ap-sdk" ;;
        ap-product-a) echo "$CI_ROOT/products/ap-product-a" ;;
        ap-product-b) echo "$CI_ROOT/products/ap-product-b" ;;
        *) echo "" ;;
    esac
}

# Print the set of package IDs found in a `conan list --format=json` file.
ci_package_ids() {
    python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

ids = set()


def walk(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "packages" and isinstance(value, dict):
                ids.update(value.keys())
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)


walk(data)
for package_id in sorted(ids):
    print(package_id)
PY
}

# Fail if the remote does not contain every package ID that exists locally.
# This is the "no recipe without binaries" gate: a recipe-only upload shows up
# as a missing package ID and must not be promoted.
ci_assert_remote_has_local() {
    local ref="$1"
    local remote="$2"
    local local_json="$3"
    local remote_json="$4"

    if ! python3 - "$ref" "$remote" "$local_json" "$remote_json" <<'PY'
import json
import sys


def collect(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    found = set()

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "packages" and isinstance(value, dict):
                    found.update(value.keys())
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(data)
    return found


ref, remote, local_path, remote_path = sys.argv[1:5]
local_ids = collect(local_path)
remote_ids = collect(remote_path)
missing = sorted(local_ids - remote_ids)
if missing:
    print(f"ERROR: {ref} is incomplete in {remote}; missing package IDs:", file=sys.stderr)
    for package_id in missing:
        print(f"  {package_id}", file=sys.stderr)
    sys.exit(1)
PY
    then
        echo "ERROR: ${ref} was not published completely to ${remote}" >&2
        exit 1
    fi
}
