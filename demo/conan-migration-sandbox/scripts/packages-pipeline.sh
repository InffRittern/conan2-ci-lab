#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v conan >/dev/null 2>&1; then
    echo "ERROR: conan not found in PATH. Install it with: uv tool install conan" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required to merge/parse JSON." >&2
    exit 1
fi

PACKAGES_REMOTE="${PACKAGES_REMOTE:-packages}"
RELEASE_PROFILE="$ROOT_DIR/profiles/linux-gcc-release"
DEBUG_PROFILE="$ROOT_DIR/profiles/linux-gcc-debug"

pkg_path="${1:-}"
version="${2:-}"
if [ -z "$pkg_path" ] || [ -z "$version" ]; then
    echo "Usage: $0 <package-path> <version>" >&2
    exit 2
fi

case "$pkg_path" in
    /*) ;;
    *) pkg_path="$ROOT_DIR/$pkg_path" ;;
esac
pkg_path="${pkg_path%/}"

if [ ! -f "$pkg_path/conanfile.py" ]; then
    echo "ERROR: no conanfile.py in $pkg_path" >&2
    exit 1
fi

name="$(basename "$pkg_path")"
case "$name" in
    ap-base) version_env="AP_BASE_VERSION" ;;
    ap-utils) version_env="AP_UTILS_VERSION" ;;
    ap-gfx) version_env="AP_GFX_VERSION" ;;
    ap-headers) version_env="AP_HEADERS_VERSION" ;;
    ap-texture) version_env="AP_TEXTURE_VERSION" ;;
    ap-box) version_env="AP_BOX_VERSION" ;;
    ap-sdk) version_env="AP_SDK_VERSION" ;;
    ap-product-a) version_env="AP_PRODUCT_A_VERSION" ;;
    ap-product-b) version_env="AP_PRODUCT_B_VERSION" ;;
    *)
        echo "ERROR: unsupported package '$name'" >&2
        exit 1
        ;;
esac

# set_version() reads the environment; the Conan CLI --version flag alone is
# not enough because set_version() assigns the value itself.
export "${version_env}=${version}"

work_dir="$ROOT_DIR/build/locks/$name"
lock_dir="$ROOT_DIR/lockfiles/packages/$name"
mkdir -p "$work_dir" "$lock_dir"

locks=()

build_config() {
    local build_type="$1"
    local profile="$2"
    local lock="$work_dir/${name}-${build_type}.lock"

    echo "=== ${name}/${version} [${build_type}] ==="

    conan lock create "$pkg_path" \
        -pr:h "$profile" -pr:b "$profile" \
        -s "build_type=$build_type" \
        -r "$PACKAGES_REMOTE" \
        --lockfile-out "$lock"

    conan create "$pkg_path" \
        -pr:h "$profile" -pr:b "$profile" \
        -s "build_type=$build_type" \
        -r "$PACKAGES_REMOTE" \
        --build=missing \
        --lockfile "$lock" \
        --lockfile-out "$lock"

    locks+=(--lockfile "$lock")
}

build_config Release "$RELEASE_PROFILE"
build_config Debug "$DEBUG_PROFILE"

echo "=== Merging configuration lockfiles for ${name}/${version} ==="
conan lock merge "${locks[@]}" --lockfile-out "$lock_dir/${name}.lock"

echo "=== Uploading ${name}/${version} to ${PACKAGES_REMOTE} ==="
conan upload "$name/$version" -r "$PACKAGES_REMOTE" -c

echo "=== Packages available in ${PACKAGES_REMOTE} ==="
conan list "$name/$version:*" -r "$PACKAGES_REMOTE"
