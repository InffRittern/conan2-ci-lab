#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v conan >/dev/null 2>&1; then
    echo "ERROR: conan not found in PATH. Install it with: uv tool install conan" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required to parse build-order JSON." >&2
    exit 1
fi

PACKAGES_REMOTE="${PACKAGES_REMOTE:-packages}"
PRODUCTS_REMOTE="${PRODUCTS_REMOTE:-products}"
DEVELOP_REMOTE="${DEVELOP_REMOTE:-develop}"
RELEASE_PROFILE="$ROOT_DIR/profiles/linux-gcc-release"
DEBUG_PROFILE="$ROOT_DIR/profiles/linux-gcc-debug"

product_path="${1:-}"
if [ -z "$product_path" ]; then
    echo "Usage: $0 <product-path>" >&2
    exit 2
fi
case "$product_path" in
    /*) ;;
    *) product_path="$ROOT_DIR/$product_path" ;;
esac
product_path="${product_path%/}"

if [ ! -f "$product_path/conanfile.py" ]; then
    echo "ERROR: no conanfile.py in $product_path" >&2
    exit 1
fi

product_name="$(basename "$product_path")"
case "$product_name" in
    ap-product-a)
        version="${AP_PRODUCT_A_VERSION:-1.0.0}"
        export AP_PRODUCT_A_VERSION="$version"
        ;;
    ap-product-b)
        version="${AP_PRODUCT_B_VERSION:-1.0.0}"
        export AP_PRODUCT_B_VERSION="$version"
        ;;
    *)
        echo "ERROR: unsupported product '$product_name'" >&2
        exit 1
        ;;
esac

version_env_for() {
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

lock_dir="$ROOT_DIR/lockfiles/$product_name"
build_dir="$ROOT_DIR/build/$product_name"
lockfile="$lock_dir/$product_name.lock"
order_release="$build_dir/$product_name-Release-order.json"
order_debug="$build_dir/$product_name-Debug-order.json"
order_merged="$build_dir/$product_name-order.json"
mkdir -p "$lock_dir" "$build_dir"

declare -A PACKAGE_PATHS=(
    [ap-base]="$ROOT_DIR/libs/ap-base"
    [ap-utils]="$ROOT_DIR/libs/ap-utils"
    [ap-gfx]="$ROOT_DIR/libs/ap-gfx"
    [ap-headers]="$ROOT_DIR/libs/ap-headers"
    [ap-texture]="$ROOT_DIR/libs/ap-texture"
    [ap-box]="$ROOT_DIR/libs/ap-box"
    [ap-sdk]="$ROOT_DIR/libs/ap-sdk"
    [ap-product-a]="$ROOT_DIR/products/ap-product-a"
    [ap-product-b]="$ROOT_DIR/products/ap-product-b"
)

profile_for() {
    case "$1" in
        Release) echo "$RELEASE_PROFILE" ;;
        Debug) echo "$DEBUG_PROFILE" ;;
        *) echo "ERROR: unknown build type $1" >&2; exit 1 ;;
    esac
}

echo "=== Creating base lockfile for ${product_name}/${version} ==="
conan lock create "$product_path" \
    -pr:h "$RELEASE_PROFILE" -pr:b "$RELEASE_PROFILE" \
    -s build_type=Release \
    -r "$PACKAGES_REMOTE" \
    --lockfile-out "$lockfile"

for build_type in Release Debug; do
    profile="$(profile_for "$build_type")"
    echo "=== Extending lockfile for ${build_type} ==="
    conan lock create "$product_path" \
        -pr:h "$profile" -pr:b "$profile" \
        -s "build_type=$build_type" \
        -r "$PACKAGES_REMOTE" \
        --lockfile "$lockfile" \
        --lockfile-out "$lockfile"
done

for build_type in Release Debug; do
    profile="$(profile_for "$build_type")"
    case "$build_type" in
        Release) order_file="$order_release" ;;
        Debug) order_file="$order_debug" ;;
    esac
    echo "=== Computing build-order for ${product_name} [${build_type}] ==="
    conan graph build-order "$product_path" \
        -pr:h "$profile" -pr:b "$profile" \
        -s "build_type=$build_type" \
        -r "$PACKAGES_REMOTE" \
        --lockfile "$lockfile" \
        --build=missing \
        --order-by=recipe \
        --format=json \
        --out-file "$order_file"
done

echo "=== Merging build-order ==="
conan graph build-order-merge \
    --file "$order_release" \
    --file "$order_debug" \
    --reduce \
    --format=json \
    --out-file "$order_merged"

refs="$(python3 - "$order_merged" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

for level in data.get("order", []):
    for node in level:
        ref = node["ref"].split("#", 1)[0]
        print(ref)
PY
)"

product_ref="$product_name/$version"
if ! grep -Fxq "$product_ref" <<< "$refs"; then
    if [ -n "$refs" ]; then
        refs="$refs
$product_ref"
    else
        refs="$product_ref"
    fi
fi

while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    name="${ref%%/*}"
    ref_version="${ref#*/}"
    pkg_path="${PACKAGE_PATHS[$name]:-}"

    if [ -z "$pkg_path" ]; then
        echo "Skipping non-local reference $ref"
        continue
    fi

    ref_version_env="$(version_env_for "$name")"
    if [ -z "$ref_version_env" ]; then
        echo "ERROR: no version environment variable for '$name'" >&2
        exit 1
    fi
    export "${ref_version_env}=${ref_version}"

    for build_type in Release Debug; do
        profile="$(profile_for "$build_type")"
        echo "=== Building ${ref} [${build_type}] ==="
        conan create "$pkg_path" \
            -pr:h "$profile" -pr:b "$profile" \
            -s "build_type=$build_type" \
            -r "$PACKAGES_REMOTE" \
            --build=missing \
            --lockfile "$lockfile" \
            --lockfile-out "$lockfile"
    done

    echo "=== Uploading ${ref} to ${PRODUCTS_REMOTE} ==="
    conan upload "$ref" -r "$PRODUCTS_REMOTE" -c
done <<< "$refs"

echo "=== Promoting ${product_name}/${version} to ${DEVELOP_REMOTE} ==="
bash "$ROOT_DIR/scripts/promote.sh" \
    "$product_name/$version:*" \
    "$PRODUCTS_REMOTE" \
    "$DEVELOP_REMOTE"

echo "=== Saving package list for ${product_name}/${version} ==="
conan list "$product_name/$version:*" \
    -r "$DEVELOP_REMOTE" \
    --format=json \
    --out-file "$lock_dir/$product_name-packagelist.json"

# Keep immutable per-version copies. The canonical files above are convenient
# for the current pipeline run; the versioned ones are what reproducibility
# scenarios use after newer library versions appear.
cp "$lockfile" "$lock_dir/$product_name-$version.lock"
cp "$lock_dir/$product_name-packagelist.json" \
    "$lock_dir/$product_name-$version-packagelist.json"

echo "Done: ${product_name}/${version}"
echo "Lockfile:     $lockfile"
echo "Package list: $lock_dir/$product_name-packagelist.json"
echo "Versioned:    $lock_dir/$product_name-$version.lock"
echo "              $lock_dir/$product_name-$version-packagelist.json"
