#!/usr/bin/env bash
# Step 6/8: Jenkins credentials and the Gitea server used for hooks.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "Step 6/8: Jenkins credentials and Gitea server"
need_container "$JENKINS_CONTAINER"
jenkins_auth_probe \
  || die "Jenkins is secured but ${JENKINS_PASS_FILE} does not contain usable credentials"
[ -s "$GITEA_TOKEN_FILE" ] || die "missing ${GITEA_TOKEN_FILE}; run 02-gitea-orgs-token.sh first"
token="$(cat "$GITEA_TOKEN_FILE")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import hudson.util.Secret
import org.jenkinsci.plugin.gitea.servers.GiteaServers
import org.jenkinsci.plugin.gitea.servers.GiteaServer

def TOKEN = '${token}'
def ARTIFACTORY_PASSWORD = '${ARTIFACTORY_ADMIN_PASSWORD}'
def store = SystemCredentialsProvider.getInstance().getStore()
def domain = Domain.global()
def creds = store.getCredentials(domain)
def upsert = { c ->
  def old = creds.find { it.id == c.id }
  if (old) {
    store.updateCredentials(domain, old, c)
    println "credentials: updated \${c.id}"
  } else {
    store.addCredentials(domain, c)
    println "credentials: created \${c.id}"
  }
}
upsert(new UsernamePasswordCredentialsImpl(CredentialsScope.GLOBAL, 'gitea-admin', 'Gitea admin PAT', 'admin', TOKEN))
upsert(new StringCredentialsImpl(CredentialsScope.GLOBAL, 'artifactory-password', 'Artifactory admin password', Secret.fromString(ARTIFACTORY_PASSWORD)))

def gs = GiteaServers.get()
gs.setServers([new GiteaServer('gitea', 'http://gitea:3000', true, 'gitea-admin')])
gs.save()
def stored = gs.findServer('http://gitea:3000')
if (stored == null) {
  throw new RuntimeException('Gitea server was not stored')
}
def c = stored.credentials()
if (c == null) {
  throw new RuntimeException('Gitea server credentials cannot be resolved')
}
println "gitea-server: ok \${stored.getServerUrl()} creds=\${c.getId()} manageHooks=\${stored.isManageHooks()}"
EOF

out="$(jenkins_script_text "$tmp")" || die "Jenkins script console failed: $out"
printf '%s\n' "$out"
printf '%s' "$out" | grep -q 'credentials: created gitea-admin\|credentials: updated gitea-admin' \
  || die "gitea-admin credential was not configured: $out"
printf '%s' "$out" | grep -q 'credentials: created artifactory-password\|credentials: updated artifactory-password' \
  || die "artifactory-password credential was not configured: $out"
printf '%s' "$out" | grep -q 'gitea-server: ok http://gitea:3000' \
  || die "Gitea server was not configured: $out"

creds_json="$(docker exec "$JENKINS_CONTAINER" curl -sg ${JENKINS_AUTH} \
  "${JENKINS_URL}/credentials/store/system/domain/_/api/json?tree=credentials[id,typeName]")"
printf '%s' "$creds_json" | grep -q '"id":"gitea-admin"' \
  || die "credentials API does not list gitea-admin: $creds_json"
printf '%s' "$creds_json" | grep -q '"id":"artifactory-password"' \
  || die "credentials API does not list artifactory-password: $creds_json"
info "both Jenkins credentials are present"

configure_html="$(docker exec "$JENKINS_CONTAINER" curl -sS ${JENKINS_AUTH} \
  "${JENKINS_URL}/configure")"
has_text "$configure_html" 'http://gitea:3000' \
  || die "/configure does not show the Gitea server URL"
has_text "$configure_html" 'gitea-admin' \
  || die "/configure does not show the Gitea credentials id"
info "Gitea server visible in /configure"

log "Step 6/8: OK"
