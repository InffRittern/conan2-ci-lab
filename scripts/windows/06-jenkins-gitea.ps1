# Step 6/8: Jenkins credentials and the Gitea server used for hooks.
. "$PSScriptRoot\lib.ps1"

Write-Log "Step 6/8: Jenkins credentials and Gitea server"
Test-ContainerRunning -Container $script:JenkinsContainer
if (-not (Test-JenkinsAuth)) {
    Stop-WithError "Jenkins is secured but $($script:JenkinsPassFile) does not contain usable credentials"
}
if (-not (Test-Path -LiteralPath $script:GiteaTokenFile) -or
    (Get-Item -LiteralPath $script:GiteaTokenFile).Length -eq 0) {
    Stop-WithError "missing $($script:GiteaTokenFile); run 02-gitea-orgs-token.ps1 first"
}
$token = (Get-Content -Raw -LiteralPath $script:GiteaTokenFile).Trim()

$groovy = @'
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import hudson.util.Secret
import org.jenkinsci.plugin.gitea.servers.GiteaServers
import org.jenkinsci.plugin.gitea.servers.GiteaServer

def TOKEN = '__TOKEN__'
def ARTIFACTORY_PASSWORD = '__ARTIFACTORY_PASSWORD__'
def store = SystemCredentialsProvider.getInstance().getStore()
def domain = Domain.global()
def creds = store.getCredentials(domain)
def upsert = { c ->
  def old = creds.find { it.id == c.id }
  if (old) {
    store.updateCredentials(domain, old, c)
    println "credentials: updated ${c.id}"
  } else {
    store.addCredentials(domain, c)
    println "credentials: created ${c.id}"
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
println "gitea-server: ok ${stored.getServerUrl()} creds=${c.getId()} manageHooks=${stored.isManageHooks()}"
'@
$groovy = $groovy.Replace('__TOKEN__', (ConvertTo-GroovySingleQuoted $token))
$groovy = $groovy.Replace('__ARTIFACTORY_PASSWORD__', (ConvertTo-GroovySingleQuoted $script:ArtifactoryAdminPassword))

$groovyFile = New-TempFileWithText -Content $groovy
try {
    $out = Invoke-JenkinsScriptText -Path $groovyFile
} finally {
    Remove-Item -LiteralPath $groovyFile -Force -ErrorAction SilentlyContinue
}
Write-Host $out
if (-not ((Test-HasText $out 'credentials: created gitea-admin') -or
        (Test-HasText $out 'credentials: updated gitea-admin'))) {
    Stop-WithError "gitea-admin credential was not configured: $out"
}
if (-not ((Test-HasText $out 'credentials: created artifactory-password') -or
        (Test-HasText $out 'credentials: updated artifactory-password'))) {
    Stop-WithError "artifactory-password credential was not configured: $out"
}
if (-not (Test-HasText $out 'gitea-server: ok http://gitea:3000')) {
    Stop-WithError "Gitea server was not configured: $out"
}

$credsJson = (Invoke-Docker -DockerArgs (@(
            'exec', $script:JenkinsContainer, 'curl', '-sg'
        ) + $script:JenkinsAuth + @(
            "$($script:JenkinsUrl)/credentials/store/system/domain/_/api/json?tree=credentials[id,typeName]"
        ))).Output
if (-not (Test-HasText $credsJson '"id":"gitea-admin"')) {
    Stop-WithError "credentials API does not list gitea-admin: $credsJson"
}
if (-not (Test-HasText $credsJson '"id":"artifactory-password"')) {
    Stop-WithError "credentials API does not list artifactory-password: $credsJson"
}
Write-Info 'both Jenkins credentials are present'

$configureHtml = (Invoke-Docker -DockerArgs (@(
            'exec', $script:JenkinsContainer, 'curl', '-sS'
        ) + $script:JenkinsAuth + @(
            "$($script:JenkinsUrl)/configure"
        ))).Output
if (-not (Test-HasText $configureHtml 'http://gitea:3000')) {
    Stop-WithError '/configure does not show the Gitea server URL'
}
if (-not (Test-HasText $configureHtml 'gitea-admin')) {
    Stop-WithError '/configure does not show the Gitea credentials id'
}
Write-Info 'Gitea server visible in /configure'

Write-Log "Step 6/8: OK"
