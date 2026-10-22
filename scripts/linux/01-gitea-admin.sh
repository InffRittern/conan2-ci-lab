#!/usr/bin/env bash
# Step 1/8: Gitea admin user and required Gitea settings.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "Step 1/8: Gitea admin user and settings"
need_container "$GITEA_CONTAINER"
wait_http "$GITEA_CONTAINER" "${GITEA_URL}/api/healthz" 120 "Gitea"

api_status() {
  gitea_admin_status "${GITEA_URL}$1"
}

verify_admin() {
  local body
  body="$(gitea_admin_curl "${GITEA_URL}/api/v1/user")"
  printf '%s' "$body" | grep -q "\"login\":\"${GITEA_ADMIN_USER}\"" \
    || die "Gitea API did not return the admin login: $body"
  printf '%s' "$body" | grep -q '"is_admin":true' \
    || die "user '${GITEA_ADMIN_USER}' is not a Gitea administrator: $body"
  info "admin '${GITEA_ADMIN_USER}' authenticates and is_admin=true"
}

admin_code="$(api_status /api/v1/user)"
if [ "$admin_code" = "200" ]; then
  info "admin '${GITEA_ADMIN_USER}' already exists with the configured password"
else
  user_code="$(gitea_curl -s -o /dev/null -w '%{http_code}' \
    "${GITEA_URL}/api/v1/users/${GITEA_ADMIN_USER}")"
  if [ "$user_code" = "200" ]; then
    info "admin exists but the password check failed (HTTP $admin_code); resetting password"
    if ! out="$(docker exec -u git "$GITEA_CONTAINER" gitea admin user change-password \
          --username "$GITEA_ADMIN_USER" --password "$GITEA_ADMIN_PASSWORD" 2>&1)"; then
      die "gitea admin user change-password failed: $out"
    fi
  elif [ "$user_code" = "404" ]; then
    info "creating Gitea admin '${GITEA_ADMIN_USER}'"
    if ! out="$(docker exec -u git "$GITEA_CONTAINER" gitea admin user create \
          --username "$GITEA_ADMIN_USER" \
          --password "$GITEA_ADMIN_PASSWORD" \
          --email "$GITEA_ADMIN_EMAIL" \
          --admin --must-change-password=false 2>&1)"; then
      die "gitea admin user create failed: $out"
    fi
  else
    die "unexpected Gitea user lookup result for '${GITEA_ADMIN_USER}': HTTP $user_code"
  fi

  # Gitea always marks the password as must-change after change-password.
  if ! out="$(docker exec -u git "$GITEA_CONTAINER" gitea admin user \
        must-change-password --unset "$GITEA_ADMIN_USER" 2>&1)"; then
    die "failed to clear must-change-password for '${GITEA_ADMIN_USER}': $out"
  fi
  info "must-change-password is disabled for '${GITEA_ADMIN_USER}'"
fi

verify_admin

# Gitea is the source repository only. Keep the package registry disabled even
# if an older stack left it enabled in app.ini.
restart_gitea=0
rc=0
ensure_gitea_ini packages ENABLED false || rc=$?
case "$rc" in
  0) info "app.ini: [packages] ENABLED = false" ;;
  10) info "app.ini: wrote [packages] ENABLED = false"; restart_gitea=1 ;;
  *) die "failed to update [packages] in app.ini (rc=$rc)" ;;
esac

# Gitea only allows webhooks to hosts listed here (or '*').
allowed="$(docker exec "$GITEA_CONTAINER" cat /data/gitea/conf/app.ini | ini_get security ALLOWED_HOST_LIST)"
if [ -z "$allowed" ]; then
  allowed_new="jenkins"
elif printf '%s' "$allowed" | tr ',' '\n' | grep -qxE '\*|jenkins'; then
  allowed_new="$allowed"
else
  allowed_new="${allowed},jenkins"
fi
if [ "$allowed_new" != "$allowed" ]; then
  rc=0
  ensure_gitea_ini security ALLOWED_HOST_LIST "$allowed_new" || rc=$?
  case "$rc" in
    0) ;;
    10) info "app.ini: ALLOWED_HOST_LIST = $allowed_new"; restart_gitea=1 ;;
    *) die "failed to update ALLOWED_HOST_LIST (rc=$rc)" ;;
  esac
else
  info "app.ini: ALLOWED_HOST_LIST allows jenkins ($allowed)"
fi

if [ "$restart_gitea" = "1" ]; then
  info "restarting Gitea to apply app.ini changes"
  docker restart "$GITEA_CONTAINER" >/dev/null
  wait_http "$GITEA_CONTAINER" "${GITEA_URL}/api/healthz" 120 "Gitea"
  verify_admin
fi

log "Step 1/8: OK"
