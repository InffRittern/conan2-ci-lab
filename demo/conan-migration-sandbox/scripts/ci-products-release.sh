#!/usr/bin/env bash
# Resolve every final product in one graph, build the whole graph, and only
# then promote the complete set to the stable repository.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/ci-lib.sh
source "$ROOT_DIR/scripts/ci-lib.sh"

ci_require_conan
ci_require_python

PACKAGES_REMOTE="${PACKAGES_REMOTE:-packages}"
PRODUCTS_REMOTE="${PRODUCTS_REMOTE:-products}"
DEVELOP_REMOTE="${DEVELOP_REMOTE:-develop}"
RESOLVE_REMOTE="${CI_RESOLVE_REMOTE:-$PRODUCTS_REMOTE}"
RELEASE_PROFILE="$ROOT_DIR/profiles/linux-gcc-release"
DEBUG_PROFILE="$ROOT_DIR/profiles/linux-gcc-debug"
PROMOTE_TO_DEVELOP="${PROMOTE_TO_DEVELOP:-1}"
DRY_RUN=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-promote) PROMOTE_TO_DEVELOP=0 ;;
        *)
            echo "Usage: $0 [--dry-run] [--no-promote]" >&2
            exit 2
            ;;
    esac
    shift
done

export AP_PRODUCT_A_VERSION="${AP_PRODUCT_A_VERSION:-1.0.0}"
export AP_PRODUCT_B_VERSION="${AP_PRODUCT_B_VERSION:-1.0.0}"

META_DIR="$ROOT_DIR/ci/all-products"
LOCK_DIR="$ROOT_DIR/lockfiles/ci"
BUILD_DIR="$ROOT_DIR/build/ci-products"
LOCKFILE="$LOCK_DIR/all-products.lock"
ORDER_RELEASE="$BUILD_DIR/all-products-Release-order.json"
ORDER_DEBUG="$BUILD_DIR/all-products-Debug-order.json"
ORDER_MERGED="$BUILD_DIR/all-products-order.json"
REFS_FILE="$BUILD_DIR/all-products-refs.txt"
MANIFEST="$LOCK_DIR/release-manifest.json"
mkdir -p "$LOCK_DIR" "$BUILD_DIR"

if [ ! -f "$META_DIR/conanfile.py" ]; then
    echo "ERROR: unified graph root not found: $META_DIR" >&2
    exit 1
fi

echo "=== Creating one consistent lockfile for all products ==="
echo "    resolve remote: ${RESOLVE_REMOTE}"
conan lock create "$META_DIR" \
    -pr:h "$RELEASE_PROFILE" -pr:b "$RELEASE_PROFILE" \
    -s build_type=Release \
    -r "$RESOLVE_REMOTE" \
    --lockfile-out "$LOCKFILE"

conan lock create "$META_DIR" \
    -pr:h "$DEBUG_PROFILE" -pr:b "$DEBUG_PROFILE" \
    -s build_type=Debug \
    -r "$RESOLVE_REMOTE" \
    --lockfile "$LOCKFILE" \
    --lockfile-out "$LOCKFILE"

for build_type in Release Debug; do
    case "$build_type" in
        Release)
            profile="$RELEASE_PROFILE"
            order_file="$ORDER_RELEASE"
            ;;
        Debug)
            profile="$DEBUG_PROFILE"
            order_file="$ORDER_DEBUG"
            ;;
    esac

    echo "=== Computing union build-order [${build_type}] ==="
    conan graph build-order "$META_DIR" \
        -pr:h "$profile" -pr:b "$profile" \
        -s "build_type=$build_type" \
        -r "$RESOLVE_REMOTE" \
        --lockfile "$LOCKFILE" \
        --build=missing \
        --order-by=recipe \
        --format=json \
        --out-file "$order_file"
done

# Do not pass --reduce here: with an already populated cache Conan can reduce
# the order to an empty list even though the graph still has to be validated.
conan graph build-order-merge \
    --file "$ORDER_RELEASE" \
    --file "$ORDER_DEBUG" \
    --format=json \
    --out-file "$ORDER_MERGED"

python3 - "$ORDER_MERGED" > "$REFS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

seen = set()
for level in data.get("order", []):
    for node in level:
        ref = node.get("ref")
        if not ref:
            continue
        ref = ref.split("#", 1)[0]
        if ref == "ap-all-products/1.0.0":
            continue
        if ref not in seen:
            seen.add(ref)
            print(ref)
PY

if [ ! -s "$REFS_FILE" ]; then
    echo "ERROR: unified graph produced an empty build order" >&2
    exit 1
fi

selected="$(grep '^ap-base/' "$REFS_FILE" || true)"
echo "=== Unified graph resolved: ${selected:-ap-base (not present)} ==="
echo "=== Build order ==="
cat "$REFS_FILE"

if [ "$DRY_RUN" = "1" ]; then
    echo "Dry run: graph is consistent; nothing was built or promoted."
    exit 0
fi

# Build everything first.  No artifact is uploaded while the product set is
# still incomplete, so a failed product cannot leave develop half-updated.
while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    name="${ref%%/*}"
    version="${ref#*/}"
    pkg_path="$(ci_path_for "$name")"

    if [ -z "$pkg_path" ]; then
        echo "Skipping external reference $ref"
        continue
    fi

    version_env="$(ci_version_env_for "$name")"
    if [ -z "$version_env" ]; then
        echo "ERROR: no version environment variable for '$name'" >&2
        exit 1
    fi
    export "${version_env}=${version}"

    for build_type in Release Debug; do
        case "$build_type" in
            Release) profile="$RELEASE_PROFILE" ;;
            Debug) profile="$DEBUG_PROFILE" ;;
        esac
        echo "=== Building ${ref} [${build_type}] ==="
        conan create "$pkg_path" \
            -pr:h "$profile" -pr:b "$profile" \
            -s "build_type=$build_type" \
            -r "$RESOLVE_REMOTE" \
            --build=missing \
            --lockfile "$LOCKFILE" \
            --lockfile-out "$LOCKFILE"
    done
done < "$REFS_FILE"

echo "=== Uploading the complete graph to ${PRODUCTS_REMOTE} ==="
while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    conan upload "$ref" -r "$PRODUCTS_REMOTE" -c
done < "$REFS_FILE"

if [ "$PROMOTE_TO_DEVELOP" = "1" ]; then
    echo "=== Promoting the complete graph to ${DEVELOP_REMOTE} ==="
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        bash "$ROOT_DIR/scripts/promote.sh" \
            "$ref:*" \
            "$PRODUCTS_REMOTE" \
            "$DEVELOP_REMOTE"
    done < "$REFS_FILE"
else
    echo "Skipped promotion to ${DEVELOP_REMOTE} (--no-promote)."
fi

for product in ap-product-a ap-product-b; do
    product_ref="$(grep "^${product}/" "$REFS_FILE" | head -1 || true)"
    if [ -z "$product_ref" ]; then
        echo "ERROR: ${product} is missing from the unified build order" >&2
        exit 1
    fi
    product_version="${product_ref#*/}"
    product_lock_dir="$ROOT_DIR/lockfiles/$product"
    mkdir -p "$product_lock_dir"

    # The unified lockfile is valid for a single product as well: it contains
    # all products and all shared dependencies, so it pins the whole release.
    cp "$LOCKFILE" "$product_lock_dir/$product.lock"
    cp "$LOCKFILE" "$product_lock_dir/$product-$product_version.lock"

    if [ "$PROMOTE_TO_DEVELOP" = "1" ]; then
        conan list "$product/$product_version:*#*" \
            -r "$DEVELOP_REMOTE" \
            --format=json \
            --out-file "$product_lock_dir/$product-packagelist.json"
        cp "$product_lock_dir/$product-packagelist.json" \
            "$product_lock_dir/$product-$product_version-packagelist.json"
    fi
done

if [ "$PROMOTE_TO_DEVELOP" = "1" ]; then
    VERIFY_REMOTE="$DEVELOP_REMOTE"
else
    VERIFY_REMOTE="$PRODUCTS_REMOTE"
fi

python3 - "$REFS_FILE" "$MANIFEST" "lockfiles/ci/all-products.lock" "$PRODUCTS_REMOTE" "$DEVELOP_REMOTE" "$VERIFY_REMOTE" "$PROMOTE_TO_DEVELOP" <<'PY'
import datetime
import json
import sys

(
    refs_path,
    manifest_path,
    lockfile,
    products_remote,
    develop_remote,
    verify_remote,
    promote_to_develop,
) = sys.argv[1:8]
with open(refs_path, encoding="utf-8") as handle:
    refs = [line.strip() for line in handle if line.strip()]

payload = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "lockfile": lockfile,
    "products_remote": products_remote,
    "develop_remote": develop_remote,
    "verify_remote": verify_remote,
    "promoted_to_develop": promote_to_develop == "1",
    "refs": refs,
    "products": [ref for ref in refs if ref.startswith("ap-product-")],
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

echo "=== Verifying release manifest in ${VERIFY_REMOTE} ==="
CI_VERIFY_REMOTE="$VERIFY_REMOTE" \
    bash "$ROOT_DIR/scripts/ci-verify-release.sh" "$MANIFEST"

echo "Done: all products built as one release set (verified in ${VERIFY_REMOTE})."
echo "Lockfile: $LOCKFILE"
echo "Manifest: $MANIFEST"
