#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v conan >/dev/null 2>&1; then
    echo "ERROR: conan not found in PATH" >&2
    exit 1
fi

PACKAGES_REMOTE="${PACKAGES_REMOTE:-packages}"
PRODUCTS_REMOTE="${PRODUCTS_REMOTE:-products}"
DEVELOP_REMOTE="${DEVELOP_REMOTE:-develop}"
ARTIFACTORY_URL="${ARTIFACTORY_URL:-http://artifactory:8082}"
CONAN_USERNAME="${CONAN_USERNAME:-admin}"
CONAN_PASSWORD="${CONAN_PASSWORD:-${ARTIFACTORY_PASSWORD:-}}"

if [ -z "$CONAN_PASSWORD" ]; then
    echo "ERROR: set CONAN_PASSWORD or ARTIFACTORY_PASSWORD" >&2
    exit 1
fi

remote_url() {
    local repo="$1"
    printf '%s/artifactory/api/conan/%s' "${ARTIFACTORY_URL%/}" "$repo"
}

ensure_remote() {
    local name="$1"
    local url
    url="$(remote_url "$name")"

    if conan remote list | grep -Eq "^${name}:"; then
        conan remote update "$name" --url "$url"
    else
        conan remote add "$name" "$url"
    fi

    conan remote login "$name" "$CONAN_USERNAME" -p "$CONAN_PASSWORD"
}

ensure_remote "$PACKAGES_REMOTE"
ensure_remote "$PRODUCTS_REMOTE"
ensure_remote "$DEVELOP_REMOTE"

# Local remotes must precede conancenter; otherwise a public package with the
# same name can shadow the internal one.
conan remote update "$PACKAGES_REMOTE" --index=0
conan remote update "$PRODUCTS_REMOTE" --index=1
conan remote update "$DEVELOP_REMOTE" --index=2
