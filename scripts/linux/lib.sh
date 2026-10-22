#!/usr/bin/env bash
# Shared environment and helpers for the local Gitea + Jenkins + Conan bootstrap.
# Sourced by every step script; keeps container names and endpoints in one place.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Optional local overrides. The file is ignored by Git; see .env.example.
if [ -f "${ROOT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${ROOT_DIR}/.env"
  set +a
fi

GITEA_CONTAINER="${GITEA_CONTAINER:-gitea}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"
CONAN_CONTAINER="${CONAN_CONTAINER:-conan}"
ARTIFACTORY_CONTAINER="${ARTIFACTORY_CONTAINER:-artifactory}"
CONAN_IMAGE="${CONAN_IMAGE:-ubuntu:24.04}"
CONAN_VOLUME="${CONAN_VOLUME:-conan_workspace}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT_DIR")}"
CI_NETWORK="${CI_NETWORK:-${COMPOSE_PROJECT_NAME}_ci_network}"

GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-password}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-admin@example.com}"
# URL used from inside the gitea container.
GITEA_URL="${GITEA_URL:-http://localhost:3000}"
# URL used from the conan/jenkins containers on ci_network.
GITEA_NETWORK_URL="${GITEA_NETWORK_URL:-http://gitea:3000}"

JENKINS_ADMIN_USER="${JENKINS_ADMIN_USER:-admin}"
JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-password}"
# URL used from inside the jenkins container.
JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"

ARTIFACTORY_URL="${ARTIFACTORY_URL:-http://localhost:8082}"
ARTIFACTORY_NETWORK_URL="${ARTIFACTORY_NETWORK_URL:-http://artifactory:8082}"
ARTIFACTORY_ADMIN_USER="${ARTIFACTORY_ADMIN_USER:-admin}"
ARTIFACTORY_ADMIN_PASSWORD="${ARTIFACTORY_ADMIN_PASSWORD:-${ARTIFACTORY_PASSWORD:-password}}"

CONAN_REMOTES=(packages products develop)
JENKINS_PLUGINS=(gitea docker-workflow workflow-aggregator git pipeline-stage-view)

SECRETS_DIR="${ROOT_DIR}/.secrets"
GITEA_TOKEN_FILE="${SECRETS_DIR}/gitea-token"
JENKINS_PASS_FILE="${SECRETS_DIR}/jenkins-pass"

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

need_container() {
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)"
  [ "$running" = "true" ] || die "container '$1' is not running"
}

# wait_http <container> <url> <timeout-seconds> <label>
wait_http() {
  local container=$1 url=$2 timeout=$3 label=$4 waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if docker exec "$container" curl -fsS -o /dev/null "$url" 2>/dev/null; then
      info "$label is ready ($url)"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  local code
  code="$(docker exec "$container" curl -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  die "$label did not become ready at $url within ${timeout}s (last HTTP code: ${code:-no response})"
}

gitea_curl() {
  docker exec "$GITEA_CONTAINER" curl -sS "$@"
}

gitea_admin_curl() {
  docker exec "$GITEA_CONTAINER" curl -sS \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" "$@"
}

# Prints the HTTP status code for an admin-authenticated Gitea API request.
gitea_admin_status() {
  local url=$1
  docker exec "$GITEA_CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" "$url"
}

# jenkins_auth_probe sets JENKINS_AUTH to "-u user:pass" when the stored
# credentials work, leaves it empty when Jenkins is unsecured, and fails when
# Jenkins is secured but the stored credentials are unusable.
JENKINS_AUTH=""
jenkins_auth_probe() {
  JENKINS_AUTH=""
  if [ -s "$JENKINS_PASS_FILE" ]; then
    local pass
    pass="$(cat "$JENKINS_PASS_FILE")"
    if docker exec "$JENKINS_CONTAINER" curl -fsS -o /dev/null \
         -u "${JENKINS_ADMIN_USER}:${pass}" "${JENKINS_URL}/whoAmI/api/json" 2>/dev/null; then
      JENKINS_AUTH="-u ${JENKINS_ADMIN_USER}:${pass}"
      return 0
    fi
  fi
  local code
  code="$(docker exec "$JENKINS_CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
          "${JENKINS_URL}/whoAmI/api/json" 2>/dev/null || true)"
  [ "$code" = "200" ] && return 0
  return 1
}

jenkins_curl() {
  docker exec "$JENKINS_CONTAINER" curl -sS "$@"
}

# Runs a Groovy script through /scriptText. Uses JENKINS_AUTH if set.
jenkins_script_text() {
  local file=$1 crumb
  crumb="$(docker exec "$JENKINS_CONTAINER" curl -sS ${JENKINS_AUTH} \
           -c /tmp/jenkins-bootstrap.cookies \
           "${JENKINS_URL}/crumbIssuer/api/json" \
           | sed -E 's/.*"crumb":"([^"]+)".*/\1/')"
  [ -n "$crumb" ] || die "could not obtain a Jenkins CSRF crumb"
  docker exec -i "$JENKINS_CONTAINER" curl -sS ${JENKINS_AUTH} \
    -b /tmp/jenkins-bootstrap.cookies \
    -H "Jenkins-Crumb: ${crumb}" \
    -X POST --data-urlencode "script@-" \
    "${JENKINS_URL}/scriptText" < "$file"
}

jenkins_plugin_json() {
  docker exec "$JENKINS_CONTAINER" curl -sg ${JENKINS_AUTH} \
    "${JENKINS_URL}/pluginManager/api/json?tree=plugins[shortName,active]"
}

# version_lt A B -> true when A < B (numeric dot-separated compare).
version_lt() {
  local a=$1 b=$2
  [ "$a" = "$b" ] && return 1
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$a" ]
}

# has_text STRING PATTERN — literal substring test that is safe with pipefail
# and large inputs (grep -q on a pipe can SIGPIPE the producer).
has_text() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ini_get SECTION KEY reads an INI file from stdin and prints the value.
ini_get() {
  awk -v s="$1" -v k="$2" '
    $0 == "[" s "]" { insec = 1; next }
    /^\[/ { insec = 0 }
    insec && $0 ~ "^[ \t]*" k "[ \t]*=" {
      sub(/^[^=]*=[ \t]*/, "")
      print
      exit
    }'
}

# ini_set SECTION KEY VALUE streams an INI file to stdout with the key set
# inside the given section (adds the section/key when missing).
ini_set() {
  awk -v s="$1" -v k="$2" -v v="$3" '
    BEGIN { insec = 0; seen = 0; done = 0 }
    $0 == "[" s "]" { insec = 1; seen = 1; print; next }
    /^\[/ {
      if (insec && !done) { print k " = " v; done = 1 }
      insec = 0
    }
    {
      if (insec && $0 ~ "^[ \t]*" k "[ \t]*=") {
        if (!done) { print k " = " v; done = 1 }
        next
      }
      print
    }
    END {
      if (insec && !done) { print k " = " v }
      if (!seen) { print ""; print "[" s "]"; print k " = " v }
    }'
}

# ensure_gitea_ini SECTION KEY VALUE
# Returns 0 when unchanged, 10 when the file was rewritten.
ensure_gitea_ini() {
  local section=$1 key=$2 value=$3
  local file=/data/gitea/conf/app.ini tmp before after
  tmp="$(mktemp)"
  docker exec "$GITEA_CONTAINER" cat "$file" > "$tmp"
  before="$(cat "$tmp")"
  after="$(ini_set "$section" "$key" "$value" < "$tmp")"
  rm -f "$tmp"
  if [ "$before" = "$after" ]; then
    return 0
  fi
  printf '%s\n' "$after" | docker exec -i -u git "$GITEA_CONTAINER" \
    sh -c "cat > $file"
  return 10
}
