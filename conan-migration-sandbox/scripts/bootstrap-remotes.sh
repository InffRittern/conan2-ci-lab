#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v conan >/dev/null 2>&1; then
    echo "ERROR: conan not found in PATH. Install it with: uv tool install conan" >&2
    exit 1
fi

PACKAGES_REMOTE="${PACKAGES_REMOTE:-packages}"
PRODUCTS_REMOTE="${PRODUCTS_REMOTE:-products}"
DEVELOP_REMOTE="${DEVELOP_REMOTE:-develop}"
ARTIFACTORY_URL="${ARTIFACTORY_URL:-http://artifactory:8082}"
CONAN_USERNAME="${CONAN_USERNAME:-admin}"
CONAN_PASSWORD="${CONAN_PASSWORD:-${ARTIFACTORY_PASSWORD:-password}}"

remote_url() {
    local repo="$1"
    printf '%s/artifactory/api/conan/%s' "${ARTIFACTORY_URL%/}" "$repo"
}

ensure_remote() {
    local name="$1"
    local repo="$2"
    local url
    url="$(remote_url "$repo")"

    if conan remote list | grep -Eq "^${name}:"; then
        echo "Updating remote ${name} -> ${url}"
        conan remote update "$name" --url "$url"
    else
        echo "Adding remote ${name} -> ${url}"
        conan remote add "$name" "$url"
    fi

    echo "Logging in to ${name} as ${CONAN_USERNAME}"
    conan remote login "$name" "$CONAN_USERNAME" -p "$CONAN_PASSWORD"
}

ensure_remote "$PACKAGES_REMOTE" "$PACKAGES_REMOTE"
ensure_remote "$PRODUCTS_REMOTE" "$PRODUCTS_REMOTE"
ensure_remote "$DEVELOP_REMOTE" "$DEVELOP_REMOTE"

# ConanCenter is added by default and must not shadow sandbox packages such as
# sfl/1.0.0. Put the Artifactory remotes first in resolution order.
conan remote update "$PACKAGES_REMOTE" --index=0
conan remote update "$PRODUCTS_REMOTE" --index=1
conan remote update "$DEVELOP_REMOTE" --index=2

echo "Configured remotes:"
conan remote list
