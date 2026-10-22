#!/usr/bin/env bash
# Build one package for every configured build type, then publish it as a
# complete unit.  Nothing is uploaded until Release and Debug have both built
# and their test_package checks have passed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/ci-lib.sh
source "$ROOT_DIR/scripts/ci-lib.sh"

ci_require_conan
ci_require_python

PACKAGES_REMOTE="${PACKAGES_REMOTE:-packages}"
PRODUCTS_REMOTE="${PRODUCTS_REMOTE:-products}"
RELEASE_PROFILE="$ROOT_DIR/profiles/linux-gcc-release"
DEBUG_PROFILE="$ROOT_DIR/profiles/linux-gcc-debug"
PROMOTE_TO_PRODUCTS="${PROMOTE_TO_PRODUCTS:-1}"

pkg_path="${1:-}"
version="${2:-}"
shift $(( $# < 2 ? $# : 2 ))
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-promote) PROMOTE_TO_PRODUCTS=0 ;;
        *)
            echo "Usage: $0 <package-path> <version> [--no-promote]" >&2
            exit 2
            ;;
    esac
    shift
done

if [ -z "$pkg_path" ] || [ -z "$version" ]; then
    echo "Usage: $0 <package-path> <version> [--no-promote]" >&2
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
version_env="$(ci_version_env_for "$name")"
if [ -z "$version_env" ]; then
    echo "ERROR: unsupported package '$name'" >&2
    exit 1
fi
export "${version_env}=${version}"

work_dir="$ROOT_DIR/build/ci-package/$name/$version"
lock_dir="$ROOT_DIR/lockfiles/packages/$name"
mkdir -p "$work_dir" "$lock_dir"

locks=()

build_config() {
    local build_type="$1"
    local profile="$2"
    local lock="$work_dir/${name}-${build_type}.lock"

    echo "=== ${name}/${version} [${build_type}] (local cache only) ==="
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
conan lock merge "${locks[@]}" --lockfile-out "$lock_dir/${name}-${version}.lock"

# The recipe must not be visible in packages before this point.  Both configs
# have been built and tested in the local cache; now publish the whole ref.
echo "=== Uploading complete ${name}/${version} (recipe + Release + Debug) to ${PACKAGES_REMOTE} ==="
conan upload "$name/$version" -r "$PACKAGES_REMOTE" -c

conan list "$name/$version:*#*" --format=json --out-file "$work_dir/local-packages.json"
conan list "$name/$version:*#*" -r "$PACKAGES_REMOTE" \
    --format=json --out-file "$work_dir/${PACKAGES_REMOTE}-packages.json"
ci_assert_remote_has_local "$name/$version" "$PACKAGES_REMOTE" \
    "$work_dir/local-packages.json" "$work_dir/${PACKAGES_REMOTE}-packages.json"

cp "$work_dir/${PACKAGES_REMOTE}-packages.json" \
    "$lock_dir/${name}-${version}-packagelist.json"

if [ "$PROMOTE_TO_PRODUCTS" = "1" ]; then
    echo "=== Promoting ${name}/${version} to ${PRODUCTS_REMOTE} ==="
    # Download first so a local cache miss cannot turn promotion into a
    # half-successful recipe-only transfer.
    conan download "$name/$version:*" -r "$PACKAGES_REMOTE"
    conan upload "$name/$version:*" -r "$PRODUCTS_REMOTE" -c

    conan list "$name/$version:*#*" -r "$PRODUCTS_REMOTE" \
        --format=json --out-file "$work_dir/${PRODUCTS_REMOTE}-packages.json"
    ci_assert_remote_has_local "$name/$version" "$PRODUCTS_REMOTE" \
        "$work_dir/local-packages.json" "$work_dir/${PRODUCTS_REMOTE}-packages.json"
    echo "Promoted to ${PRODUCTS_REMOTE}."
else
    echo "Skipped promotion to ${PRODUCTS_REMOTE} (--no-promote)."
fi

echo "Done: ${name}/${version}"
echo "Lockfile: $lock_dir/${name}-${version}.lock"
if [ "$PROMOTE_TO_PRODUCTS" = "1" ]; then
    echo "Remote:   $PACKAGES_REMOTE -> $PRODUCTS_REMOTE"
else
    echo "Remote:   $PACKAGES_REMOTE (not promoted)"
fi
