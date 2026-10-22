#!/usr/bin/env bash
# Step 4/8: Conan remotes, authentication and compatibility plugin.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "Step 4/8: Conan remotes and authentication"
need_container "$CONAN_CONTAINER"
token="$ARTIFACTORY_ADMIN_PASSWORD"

# Conan 2.33 requires the plugin file and a callable compatibility().
# Deleting or emptying the file makes every command fail, so disable it by
# returning no fallbacks instead.
docker exec -i "$CONAN_CONTAINER" sh -c '
  d="$(conan config home)/extensions/plugins/compatibility"
  mkdir -p "$d"
  cat > "$d/compatibility.py"' <<'PY'
# Disabled by bootstrap: no binary compatibility fallbacks are generated.
def compatibility(conanfile):
    return []
PY
docker exec "$CONAN_CONTAINER" sh -c '
  rm -f "$(conan config home)/extensions/plugins/compatibility/compatibility.py.disabled"'
docker exec "$CONAN_CONTAINER" sh -c '
  f="$(conan config home)/extensions/plugins/compatibility/compatibility.py"
  grep -q "^def compatibility(conanfile):" "$f" && grep -q "return \[\]" "$f"'
info "compatibility plugin replaced with a no-op (no fallbacks)"

docker exec "$CONAN_CONTAINER" conan profile show >/dev/null 2>&1 \
  || die "conan profile show fails after writing compatibility.py"

for remote in "${CONAN_REMOTES[@]}"; do
  url="${ARTIFACTORY_NETWORK_URL}/artifactory/api/conan/${remote}"
  current="$(docker exec "$CONAN_CONTAINER" conan remote list \
    | sed -nE "s/^${remote}: ([^ ]+) .*/\1/p")"
  if [ -z "$current" ]; then
    docker exec "$CONAN_CONTAINER" conan remote add "$remote" "$url" >/dev/null
    info "remote '$remote' added: $url"
  elif [ "$current" != "$url" ]; then
    docker exec "$CONAN_CONTAINER" conan remote update "$remote" "$url" >/dev/null
    info "remote '$remote' updated: $url"
  else
    info "remote '$remote' already points to $url"
  fi

  if ! out="$(docker exec -e ARTIFACTORY_PASSWORD="$token" "$CONAN_CONTAINER" \
        sh -c "conan remote login '${remote}' '${ARTIFACTORY_ADMIN_USER}' -p \"\$ARTIFACTORY_PASSWORD\"" 2>&1)"; then
    printf '%s\n' "$out" >&2
    die "conan remote login failed for '$remote'"
  fi
  info "remote '$remote': logged in as '$ARTIFACTORY_ADMIN_USER'"
done

remotes="$(docker exec "$CONAN_CONTAINER" conan remote list)"
for remote in "${CONAN_REMOTES[@]}"; do
  url="${ARTIFACTORY_NETWORK_URL}/artifactory/api/conan/${remote}"
  printf '%s\n' "$remotes" | grep -q "^${remote}: ${url} " \
    || die "remote '$remote' does not point to $url"
done
info "remote URLs verified"

users="$(docker exec "$CONAN_CONTAINER" conan remote list-users)"
for remote in "${CONAN_REMOTES[@]}"; do
  printf '%s\n' "$users" | grep -A3 "^${remote}:" \
    | grep -q "Username: ${ARTIFACTORY_ADMIN_USER}" \
    || die "remote '$remote' has no stored user '${ARTIFACTORY_ADMIN_USER}'"
  printf '%s\n' "$users" | grep -A3 "^${remote}:" \
    | grep -q "authenticated: True" \
    || die "remote '$remote' is not authenticated"
done
info "stored credentials verified for all remotes"

for remote in "${CONAN_REMOTES[@]}"; do
  if ! out="$(docker exec "$CONAN_CONTAINER" conan list '*' -r="$remote" 2>&1)"; then
    printf '%s\n' "$out" >&2
    die "authenticated access to remote '$remote' failed"
  fi
  info "remote '$remote': authenticated API access OK"
done

log "Step 4/8: OK"
