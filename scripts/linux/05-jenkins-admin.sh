#!/usr/bin/env bash
# Step 5/8: Jenkins plugins, admin account and security.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "Step 5/8: Jenkins plugins and security"
need_container "$JENKINS_CONTAINER"
wait_http "$JENKINS_CONTAINER" "${JENKINS_URL}/login" 300 "Jenkins"

jenkins_auth_probe \
  || die "Jenkins is secured but ${JENKINS_PASS_FILE} does not contain usable credentials"

# Install into the volume-backed home. The image's ref/plugins directory is an
# image layer and is lost when the container is recreated.
info "ensuring plugins: ${JENKINS_PLUGINS[*]}"
docker exec -u jenkins "$JENKINS_CONTAINER" jenkins-plugin-cli \
  --plugin-download-directory /var/jenkins_home/plugins \
  --plugins "${JENKINS_PLUGINS[@]}"

for plugin in "${JENKINS_PLUGINS[@]}"; do
  docker exec "$JENKINS_CONTAINER" test -f "/var/jenkins_home/plugins/${plugin}.jpi" \
    || die "plugin '$plugin' was not installed into /var/jenkins_home/plugins"
done
info "plugin files present"

# Restart only when the running instance does not know one of the plugins.
plugins_json="$(jenkins_plugin_json)"
restart=0
for plugin in "${JENKINS_PLUGINS[@]}"; do
  if ! has_text "$plugins_json" "\"shortName\":\"${plugin}\""; then
    restart=1
  fi
done
if [ "$restart" = "1" ]; then
  info "restarting Jenkins to load new plugins"
  docker restart "$JENKINS_CONTAINER" >/dev/null
  wait_http "$JENKINS_CONTAINER" "${JENKINS_URL}/login" 300 "Jenkins"
  jenkins_auth_probe \
    || die "Jenkins is secured but ${JENKINS_PASS_FILE} does not contain usable credentials"
  plugins_json="$(jenkins_plugin_json)"
fi
for plugin in "${JENKINS_PLUGINS[@]}"; do
  has_text "$plugins_json" "\"shortName\":\"${plugin}\"" \
    || die "plugin '$plugin' is installed but not loaded by Jenkins"
done
info "all plugins are loaded"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
import jenkins.model.*
import hudson.security.*

def j = Jenkins.get()
def loc = j.getDescriptorByType(JenkinsLocationConfiguration.class)
if (loc.getUrl() != 'http://jenkins:8080/') {
  loc.setUrl('http://jenkins:8080/')
  loc.save()
  println 'jenkins-url: set'
} else {
  println 'jenkins-url: ok'
}

def realm = j.getSecurityRealm()
if (!(realm instanceof HudsonPrivateSecurityRealm)) {
  realm = new HudsonPrivateSecurityRealm(false)
  j.setSecurityRealm(realm)
  def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
  strategy.setAllowAnonymousRead(false)
  j.setAuthorizationStrategy(strategy)
  j.save()
  println 'security: configured'
} else {
  println 'security: already configured'
}
if (realm.getUser('${JENKINS_ADMIN_USER}') == null) {
  realm.createAccount('${JENKINS_ADMIN_USER}', '${JENKINS_ADMIN_PASSWORD}')
  j.save()
  println 'admin: created'
} else {
  println 'admin: exists'
}
EOF

out="$(jenkins_script_text "$tmp")" || die "Jenkins script console failed: $out"
printf '%s\n' "$out"
printf '%s' "$out" | grep -q 'jenkins-url:' || die "Jenkins URL was not configured: $out"
printf '%s' "$out" | grep -q 'security: configured\|security: already configured' \
  || die "Jenkins security was not configured: $out"
printf '%s' "$out" | grep -q 'admin: created\|admin: exists' \
  || die "Jenkins admin was not ensured: $out"

printf '%s' "$JENKINS_ADMIN_PASSWORD" > "$JENKINS_PASS_FILE"
chmod 600 "$JENKINS_PASS_FILE"
info "admin password saved to ${JENKINS_PASS_FILE}"

code="$(docker exec "$JENKINS_CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
  -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
  "${JENKINS_URL}/whoAmI/api/json")"
[ "$code" = "200" ] || die "admin login failed after configuration (HTTP $code)"
body="$(docker exec "$JENKINS_CONTAINER" curl -sS \
  -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
  "${JENKINS_URL}/whoAmI/api/json")"
printf '%s' "$body" | grep -q '"name":"'"${JENKINS_ADMIN_USER}"'"' \
  || die "unexpected /whoAmI response: $body"
info "admin login verified: $body"

anon="$(docker exec "$JENKINS_CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
  "${JENKINS_URL}/api/json")"
[ "$anon" = "403" ] || die "anonymous access is not denied (HTTP $anon)"
info "anonymous access is denied"

log "Step 5/8: OK"
