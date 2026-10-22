#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v conan >/dev/null 2>&1; then
    echo "ERROR: conan not found in PATH. Install it with: uv tool install conan" >&2
    exit 1
fi

pkg="${1:-}"
old_version="${2:-}"
new_version="${3:-}"
if [ -z "$pkg" ] || [ -z "$old_version" ] || [ -z "$new_version" ]; then
    echo "Usage: $0 <pkg> <old-version> <new-version>" >&2
    exit 2
fi

case "$pkg" in
    ap-base|ap-utils|ap-gfx|ap-headers|ap-texture|ap-box|ap-sdk)
        pkg_path="$ROOT_DIR/libs/$pkg"
        ;;
    ap-product-a|ap-product-b)
        pkg_path="$ROOT_DIR/products/$pkg"
        ;;
    /*)
        pkg_path="$pkg"
        ;;
    *)
        echo "ERROR: unknown package '$pkg'" >&2
        exit 1
        ;;
esac

if [ ! -f "$pkg_path/conanfile.py" ]; then
    echo "ERROR: no conanfile.py in $pkg_path" >&2
    exit 1
fi

PACKAGES_REMOTE="${PACKAGES_REMOTE:-packages}"
PRODUCTS_REMOTE="${PRODUCTS_REMOTE:-products}"

echo "=== Releasing ${pkg}/${new_version} (previous: ${old_version}) ==="
bash "$ROOT_DIR/scripts/packages-pipeline.sh" "$pkg_path" "$new_version"

echo "=== Promoting ${pkg}/${new_version} to ${PRODUCTS_REMOTE} ==="
bash "$ROOT_DIR/scripts/promote.sh" \
    "$pkg/$new_version:*" \
    "$PACKAGES_REMOTE" \
    "$PRODUCTS_REMOTE"

overall=0
for product in ap-product-a ap-product-b; do
    echo "=== Building ${product} with current version ranges ==="
    echo "    (a new major of ${pkg} is ignored until ranges are widened)"
    if bash "$ROOT_DIR/scripts/products-pipeline.sh" "$ROOT_DIR/products/$product"; then
        echo "RESULT: ${product} built successfully."
    else
        echo "RESULT: ${product} FAILED to build." >&2
        overall=1
    fi
done

if [ "$overall" -ne 0 ]; then
    echo "One or more products failed. Inspect the logs and fix the consumers" >&2
    echo "or roll back to ${pkg}/${old_version}; nothing was rolled back automatically." >&2
    exit 1
fi

echo "Products built with the current ranges."
echo "Check the lockfile to confirm which ${pkg} version was actually selected."
