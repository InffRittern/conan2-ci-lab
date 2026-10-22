#!/usr/bin/env bash
# Step 3/8: Conan toolchain and the default profile (gcc 13, C++17).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "Step 3/8: Conan toolchain and profile"
need_container "$CONAN_CONTAINER"

# The sidecar is a plain ubuntu image on first use.
if ! docker exec "$CONAN_CONTAINER" bash -c '
      command -v gcc >/dev/null &&
      command -v g++ >/dev/null &&
      command -v cmake >/dev/null &&
      command -v ninja >/dev/null &&
      command -v git >/dev/null &&
      command -v python3 >/dev/null &&
      python3 -m pip --version >/dev/null 2>&1'; then
  info "installing build tools in '$CONAN_CONTAINER'"
  docker exec "$CONAN_CONTAINER" bash -c '
    apt-get update -qq &&
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      python3 python3-pip python3-venv gcc g++ cmake ninja-build git ca-certificates curl'
fi

conan_version_of() {
  local out
  # docker writes OCI errors to stdout, so check the exit status first.
  out="$(docker exec "$CONAN_CONTAINER" conan --version 2>&1)" || return 1
  awk '{print $3}' <<<"$out"
}

conan_version=""
conan_version="$(conan_version_of)" || conan_version=""
if [ -z "$conan_version" ] || version_lt "$conan_version" "2.32"; then
  info "installing conan>=2.32 (found: ${conan_version:-none})"
  docker exec "$CONAN_CONTAINER" python3 -m pip install --break-system-packages -q 'conan>=2.32'
  conan_version="$(conan_version_of)" \
    || die "conan is still not runnable after pip install"
fi
version_lt "$conan_version" "2.32" && die "Conan $conan_version is older than 2.32"
info "conan $conan_version"

gcc_major="$(docker exec "$CONAN_CONTAINER" gcc -dumpversion | cut -d. -f1)"
[ "$gcc_major" = "13" ] || die "expected gcc 13 in '$CONAN_CONTAINER', found $gcc_major"
info "gcc $gcc_major"

apply_cppstd() {
  docker exec "$CONAN_CONTAINER" bash -c '
    f="$(conan config home)/profiles/default"
    if grep -q "^compiler.cppstd=" "$f"; then
      sed -i "s/^compiler.cppstd=.*/compiler.cppstd=17/" "$f"
    else
      printf "compiler.cppstd=17\n" >> "$f"
    fi'
}

if ! docker exec "$CONAN_CONTAINER" bash -c 'test -f "$(conan config home)/profiles/default"'; then
  info "detecting default Conan profile"
  docker exec "$CONAN_CONTAINER" conan profile detect --force
fi
apply_cppstd

profile_ok() {
  docker exec "$CONAN_CONTAINER" conan profile show 2>/dev/null \
    | grep -qx 'compiler=gcc' \
    && docker exec "$CONAN_CONTAINER" conan profile show 2>/dev/null \
    | grep -qx 'compiler.version=13' \
    && docker exec "$CONAN_CONTAINER" conan profile show 2>/dev/null \
    | grep -qx 'compiler.cppstd=17'
}

if ! profile_ok; then
  info "profile does not match gcc/13/17; regenerating it"
  docker exec "$CONAN_CONTAINER" conan profile detect --force
  apply_cppstd
fi
profile_ok || die "Conan default profile is not gcc/13/17: $(docker exec "$CONAN_CONTAINER" conan profile show 2>&1)"
info "default profile: gcc 13, cppstd 17"

log "Step 3/8: OK"
