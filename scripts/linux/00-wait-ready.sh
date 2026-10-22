#!/usr/bin/env bash
# Step 0/8: wait until the compose services and the Conan sidecar are ready.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "Step 0/8: waiting for Gitea, Jenkins, Artifactory and the Conan container"

docker network inspect "$CI_NETWORK" >/dev/null 2>&1 \
  || die "docker network '$CI_NETWORK' not found; start the stack with 'docker compose up -d'"

for c in "$GITEA_CONTAINER" "$JENKINS_CONTAINER" "$ARTIFACTORY_CONTAINER"; do
  need_container "$c"
  info "container '$c' is running"
done

# Compose defines the conan service; keep a fallback for stacks created before
# that service existed.
if ! docker inspect "$CONAN_CONTAINER" >/dev/null 2>&1; then
  info "creating Conan sidecar '$CONAN_CONTAINER' ($CONAN_IMAGE) on $CI_NETWORK"
  docker run -d \
    --name "$CONAN_CONTAINER" \
    --hostname "$CONAN_CONTAINER" \
    --network "$CI_NETWORK" \
    -v "${CONAN_VOLUME}:/workspace" \
    "$CONAN_IMAGE" sleep infinity >/dev/null
elif [ "$(docker inspect -f '{{.State.Running}}' "$CONAN_CONTAINER")" != "true" ]; then
  info "starting stopped Conan sidecar"
  docker start "$CONAN_CONTAINER" >/dev/null
fi
need_container "$CONAN_CONTAINER"
docker exec "$CONAN_CONTAINER" true
info "container '$CONAN_CONTAINER' is running"

# Gitea health check includes the database.
wait_http "$GITEA_CONTAINER" "${GITEA_URL}/api/healthz" 120 "Gitea"

# /login is served anonymously even after security is enabled.
wait_http "$JENKINS_CONTAINER" "${JENKINS_URL}/login" 300 "Jenkins"

wait_http "$ARTIFACTORY_CONTAINER" \
  "${ARTIFACTORY_URL}/artifactory/api/system/ping" 300 "Artifactory"

log "Step 0/8: OK"
