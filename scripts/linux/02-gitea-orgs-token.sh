#!/usr/bin/env bash
# Step 2/8: Gitea organizations and the Conan CI access token.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "Step 2/8: Gitea organizations and API token"
need_container "$GITEA_CONTAINER"

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# 01 must have produced a working admin.
[ "$(gitea_admin_status "${GITEA_URL}/api/v1/user")" = "200" ] \
  || die "Gitea admin '${GITEA_ADMIN_USER}' is not usable; run 01-gitea-admin.sh first"

for org in "${CONAN_REMOTES[@]}"; do
  code="$(gitea_admin_status "${GITEA_URL}/api/v1/orgs/${org}")"
  if [ "$code" = "200" ]; then
    info "organization '$org' already exists"
    continue
  fi
  [ "$code" = "404" ] || die "unexpected GET /orgs/$org: HTTP $code"

  resp="$(gitea_admin_curl -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${org}\",\"visibility\":\"public\"}" \
    -w '\n%{http_code}' \
    "${GITEA_URL}/api/v1/orgs")"
  body="$(printf '%s' "$resp" | sed '$d')"
  code="$(printf '%s' "$resp" | tail -n1)"
  case "$code" in
    201) info "organization '$org' created" ;;
    422) info "organization '$org' already exists (422)" ;;
    *) die "failed to create organization '$org' (HTTP $code): $body" ;;
  esac
  [ "$(gitea_admin_status "${GITEA_URL}/api/v1/orgs/${org}")" = "200" ] \
    || die "organization '$org' is not readable after creation"
done

# Reuse the saved token only if Gitea still accepts it.
token=""
if [ -s "$GITEA_TOKEN_FILE" ]; then
  candidate="$(cat "$GITEA_TOKEN_FILE")"
  code="$(gitea_curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: token ${candidate}" "${GITEA_URL}/api/v1/user")"
  if [ "$code" = "200" ]; then
    token="$candidate"
    info "reusing token from ${GITEA_TOKEN_FILE}"
  else
    info "saved token is no longer valid (HTTP $code); creating a new one"
  fi
fi

if [ -z "$token" ]; then
  # Remove stale tokens with the same name so reruns do not accumulate them.
  tokens_json="$(gitea_admin_curl "${GITEA_URL}/api/v1/users/${GITEA_ADMIN_USER}/tokens")"
  ids="$(printf '%s' "$tokens_json" \
    | sed -E 's/\},\{/\}\n\{/g' \
    | sed -nE 's/.*"id":([0-9]+),"name":"conan-ci".*/\1/p')"
  for id in $ids; do
    code="$(gitea_admin_curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      "${GITEA_URL}/api/v1/users/${GITEA_ADMIN_USER}/tokens/${id}")"
    [ "$code" = "204" ] || die "failed to delete old token id=$id (HTTP $code)"
    info "deleted old token id=$id"
  done

  resp="$(gitea_admin_curl -X POST \
    -H 'Content-Type: application/json' \
    -d '{"name":"conan-ci","scopes":["write:organization","read:organization","read:user","read:repository","write:repository"]}' \
    "${GITEA_URL}/api/v1/users/${GITEA_ADMIN_USER}/tokens")"
  token="$(printf '%s' "$resp" | sed -E 's/.*"sha1":"([^"]+)".*/\1/')"
  case "$token" in
    *[!0-9a-f]*|'') die "Gitea did not return a token: $resp" ;;
  esac
  [ "${#token}" -ge 40 ] || die "unexpected token length ${#token}: $resp"

  printf '%s' "$token" > "$GITEA_TOKEN_FILE"
  chmod 600 "$GITEA_TOKEN_FILE"
  info "created token 'conan-ci' and saved it to ${GITEA_TOKEN_FILE}"
fi

[ -n "$token" ] || die "empty Gitea token"
code="$(gitea_curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: token ${token}" "${GITEA_URL}/api/v1/user")"
[ "$code" = "200" ] || die "token verification failed (HTTP $code)"
info "token authenticates against the Gitea API"

log "Step 2/8: OK"
