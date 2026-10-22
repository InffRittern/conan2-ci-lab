# Step 5/8: Jenkins plugins, admin account and security.
. "$PSScriptRoot\lib.ps1"

Write-Log "Step 5/8: Jenkins plugins and security"
Test-ContainerRunning -Container $script:JenkinsContainer
Wait-Http -Container $script:JenkinsContainer -Url "$($script:JenkinsUrl)/login" -TimeoutSeconds 300 -Label 'Jenkins'

if (-not (Test-JenkinsAuth)) {
    Stop-WithError "Jenkins is secured but $($script:JenkinsPassFile) does not contain usable credentials"
}

# Install into the volume-backed home. The image's ref/plugins directory is an
# image layer and is lost when the container is recreated.
Write-Info "ensuring plugins: $($script:JenkinsPlugins -join ' ')"
$installArgs = @(
    'exec', '-u', 'jenkins', $script:JenkinsContainer, 'jenkins-plugin-cli',
    '--plugin-download-directory', '/var/jenkins_home/plugins', '--plugins'
) + $script:JenkinsPlugins
$install = Invoke-Docker -DockerArgs $installArgs -AllowFailure
if ($install.ExitCode -ne 0) {
    Stop-WithError "jenkins-plugin-cli failed: $($install.Output)"
}

foreach ($plugin in $script:JenkinsPlugins) {
    $exists = Invoke-Docker -DockerArgs @(
        'exec', $script:JenkinsContainer, 'test', '-f', "/var/jenkins_home/plugins/$plugin.jpi"
    ) -AllowFailure
    if ($exists.ExitCode -ne 0) {
        Stop-WithError "plugin '$plugin' was not installed into /var/jenkins_home/plugins"
    }
}
Write-Info 'plugin files present'

# Restart only when the running instance does not know one of the plugins.
$pluginsJson = Get-JenkinsPluginJson
$restart = $false
foreach ($plugin in $script:JenkinsPlugins) {
    if (-not (Test-HasText $pluginsJson ('"shortName":"' + $plugin + '"'))) {
        $restart = $true
    }
}
if ($restart) {
    Write-Info 'restarting Jenkins to load new plugins'
    Invoke-Docker -DockerArgs @('restart', $script:JenkinsContainer) | Out-Null
    Wait-Http -Container $script:JenkinsContainer -Url "$($script:JenkinsUrl)/login" -TimeoutSeconds 300 -Label 'Jenkins'
    if (-not (Test-JenkinsAuth)) {
        Stop-WithError "Jenkins is secured but $($script:JenkinsPassFile) does not contain usable credentials"
    }
    $pluginsJson = Get-JenkinsPluginJson
}
foreach ($plugin in $script:JenkinsPlugins) {
    if (-not (Test-HasText $pluginsJson ('"shortName":"' + $plugin + '"'))) {
        Stop-WithError "plugin '$plugin' is installed but not loaded by Jenkins"
    }
}
Write-Info 'all plugins are loaded'

$groovy = @'
import jenkins.model.*
import hudson.security.*

def j = Jenkins.get()
def loc = j.getDescriptorByType(JenkinsLocationConfiguration.class)
if (loc.getUrl() != '__JENKINS_URL__') {
  loc.setUrl('__JENKINS_URL__')
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
if (realm.getUser('__ADMIN_USER__') == null) {
  realm.createAccount('__ADMIN_USER__', '__ADMIN_PASSWORD__')
  j.save()
  println 'admin: created'
} else {
  println 'admin: exists'
}
'@
$groovy = $groovy.Replace('__JENKINS_URL__', 'http://jenkins:8080/')
$groovy = $groovy.Replace('__ADMIN_USER__', (ConvertTo-GroovySingleQuoted $script:JenkinsAdminUser))
$groovy = $groovy.Replace('__ADMIN_PASSWORD__', (ConvertTo-GroovySingleQuoted $script:JenkinsAdminPassword))

$groovyFile = New-TempFileWithText -Content $groovy
try {
    $out = Invoke-JenkinsScriptText -Path $groovyFile
} finally {
    Remove-Item -LiteralPath $groovyFile -Force -ErrorAction SilentlyContinue
}
Write-Host $out
if (-not (Test-HasText $out 'jenkins-url:')) {
    Stop-WithError "Jenkins URL was not configured: $out"
}
if (-not ((Test-HasText $out 'security: configured') -or (Test-HasText $out 'security: already configured'))) {
    Stop-WithError "Jenkins security was not configured: $out"
}
if (-not ((Test-HasText $out 'admin: created') -or (Test-HasText $out 'admin: exists'))) {
    Stop-WithError "Jenkins admin was not ensured: $out"
}

[IO.File]::WriteAllText($script:JenkinsPassFile, $script:JenkinsAdminPassword,
    (New-Object System.Text.UTF8Encoding($false)))
Set-SecretPermissions -Path $script:JenkinsPassFile
Write-Info "admin password saved to $($script:JenkinsPassFile)"

$adminArgs = @(
    'exec', $script:JenkinsContainer, 'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
    '-u', "$($script:JenkinsAdminUser):$($script:JenkinsAdminPassword)",
    "$($script:JenkinsUrl)/whoAmI/api/json"
)
$code = (Invoke-Docker -DockerArgs $adminArgs).Output.Trim()
if ($code -ne '200') {
    Stop-WithError "admin login failed after configuration (HTTP $code)"
}
$body = (Invoke-Docker -DockerArgs @(
        'exec', $script:JenkinsContainer, 'curl', '-sS',
        '-u', "$($script:JenkinsAdminUser):$($script:JenkinsAdminPassword)",
        "$($script:JenkinsUrl)/whoAmI/api/json"
    )).Output
if (-not (Test-HasText $body ('"name":"' + $script:JenkinsAdminUser + '"'))) {
    Stop-WithError "unexpected /whoAmI response: $body"
}
Write-Info "admin login verified: $body"

$anon = (Invoke-Docker -DockerArgs @(
        'exec', $script:JenkinsContainer, 'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
        "$($script:JenkinsUrl)/api/json"
    )).Output.Trim()
if ($anon -ne '403') {
    Stop-WithError "anonymous access is not denied (HTTP $anon)"
}
Write-Info 'anonymous access is denied'

Write-Log "Step 5/8: OK"
