#!/usr/bin/env bash
# Step 7/8: end-to-end smoke test through the packages -> products -> develop flow.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "Step 7/8: Conan smoke test"
need_container "$CONAN_CONTAINER"

cleanup() {
  local remote
  for remote in "${CONAN_REMOTES[@]}"; do
    docker exec "$CONAN_CONTAINER" sh -c \
      "conan remove 'smoke/*' -r='${remote}' -c" >/dev/null 2>&1 || true
  done
  docker exec "$CONAN_CONTAINER" sh -c "conan remove 'smoke/*' -c" >/dev/null 2>&1 || true
}

# Leave no stale package behind if an earlier run failed midway.
cleanup
trap cleanup EXIT

docker exec -i "$CONAN_CONTAINER" bash -s <<'EOS'
set -euo pipefail
workdir=/tmp/conan-smoke
rm -rf "$workdir"
mkdir -p "$workdir"
cd "$workdir"
cat > conanfile.py <<'PY'
from conan import ConanFile


class SmokeConan(ConanFile):
    name = "smoke"
    version = "0.1.0"
    settings = "os", "arch", "compiler", "build_type"
PY

run() {
  local label=$1
  shift
  echo "--- $label"
  if ! "$@" >/tmp/conan-smoke.log 2>&1; then
    cat /tmp/conan-smoke.log
    exit 1
  fi
}

list_has() {
  local ref=$1 remote=$2
  if ! conan list "$ref" -r="$remote" 2>/dev/null | grep -c "smoke/0.1.0" >/dev/null; then
    conan list "$ref" -r="$remote" || true
    echo "ERROR: smoke/0.1.0 is not listed on remote '$remote'"
    exit 1
  fi
}

run "conan create" conan create . -s build_type=Release

run "upload to packages" conan upload "smoke/0.1.0:*" -r=packages -c
list_has "smoke/0.1.0:*" packages

run "download back from packages" conan download "smoke/0.1.0:*" -r=packages

for target in products develop; do
  run "promote to $target" conan upload "smoke/0.1.0:*" -r="$target" -c
  list_has "smoke/0.1.0:*" "$target"
done

echo "smoke: uploaded, listed and downloaded on packages/products/develop"
EOS

cleanup
trap - EXIT

for remote in "${CONAN_REMOTES[@]}"; do
  out="$(docker exec "$CONAN_CONTAINER" conan list 'smoke/*' -r="$remote" 2>&1 || true)"
  if has_text "$out" 'smoke/0.1.0'; then
    die "smoke package still present on remote '$remote' after cleanup"
  fi
  info "remote '$remote': smoke package removed"
done

log "Step 7/8: OK (smoke package cleaned up)"
