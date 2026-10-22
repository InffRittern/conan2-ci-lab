# Step 4/8: Conan remotes, authentication and compatibility plugin.
. "$PSScriptRoot\lib.ps1"

Write-Log "Step 4/8: Conan remotes and authentication"
Test-ContainerRunning -Container $script:ConanContainer
$token = $script:ArtifactoryAdminPassword

# Conan 2.33 requires the plugin file and a callable compatibility().
# Deleting or emptying the file makes every command fail, so disable it by
# returning no fallbacks instead.
$conanHome = (Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'config', 'home'
    )).Output.Trim()
if ([string]::IsNullOrEmpty($conanHome)) {
    Stop-WithError 'could not resolve the Conan home directory'
}
$compatDir = "$conanHome/extensions/plugins/compatibility"
$compatFile = "$compatDir/compatibility.py"
Invoke-Docker -DockerArgs @('exec', $script:ConanContainer, 'mkdir', '-p', $compatDir) | Out-Null

$plugin = "# Disabled by bootstrap: no binary compatibility fallbacks are generated.`n" +
    "def compatibility(conanfile):`n    return []`n"
$hostPlugin = New-TempFileWithText -Content $plugin
try {
    Invoke-Docker -DockerArgs @('cp', $hostPlugin, "$($script:ConanContainer):$compatFile") | Out-Null
} finally {
    Remove-Item -LiteralPath $hostPlugin -Force -ErrorAction SilentlyContinue
}
Invoke-Docker -DockerArgs @(
    'exec', $script:ConanContainer, 'rm', '-f', "$compatFile.disabled"
) -AllowFailure | Out-Null

$written = (Invoke-Docker -DockerArgs @('exec', $script:ConanContainer, 'cat', $compatFile)).Output
if (-not ((Test-HasText $written 'def compatibility(conanfile):') -and
        (Test-HasText $written 'return []'))) {
    Stop-WithError "compatibility.py was not written correctly: $written"
}
Write-Info 'compatibility plugin replaced with a no-op (no fallbacks)'

$profileCheck = Invoke-Docker -DockerArgs @(
    'exec', $script:ConanContainer, 'conan', 'profile', 'show'
) -AllowFailure
if ($profileCheck.ExitCode -ne 0) {
    Stop-WithError "conan profile show fails after writing compatibility.py: $($profileCheck.Output)"
}

function Get-RemoteUrl {
    param([string]$Text, [string]$Name)
    $pattern = '^' + [regex]::Escape($Name) + ':\s+(\S+)'
    foreach ($line in ($Text -split "`r?`n")) {
        $match = [regex]::Match($line, $pattern)
        if ($match.Success) { return $match.Groups[1].Value }
    }
    return ''
}

foreach ($remote in $script:ConanRemotes) {
    $url = "$($script:ArtifactoryNetworkUrl)/artifactory/api/conan/$remote"
    $listText = (Invoke-Docker -DockerArgs @(
            'exec', $script:ConanContainer, 'conan', 'remote', 'list'
        )).Output
    $current = Get-RemoteUrl -Text $listText -Name $remote
    if ([string]::IsNullOrEmpty($current)) {
        $added = Invoke-Docker -DockerArgs @(
            'exec', $script:ConanContainer, 'conan', 'remote', 'add', $remote, $url
        ) -AllowFailure
        if ($added.ExitCode -ne 0) { Stop-WithError "failed to add remote '$remote': $($added.Output)" }
        Write-Info "remote '$remote' added: $url"
    } elseif ($current -ne $url) {
        $updated = Invoke-Docker -DockerArgs @(
            'exec', $script:ConanContainer, 'conan', 'remote', 'update', $remote, $url
        ) -AllowFailure
        if ($updated.ExitCode -ne 0) { Stop-WithError "failed to update remote '$remote': $($updated.Output)" }
        Write-Info "remote '$remote' updated: $url"
    } else {
        Write-Info "remote '$remote' already points to $url"
    }

    $login = Invoke-ContainerShell -Container $script:ConanContainer -Script @'
conan remote login "$CONAN_REMOTE" "$CONAN_USER" -p "$ARTIFACTORY_PASSWORD"
'@ -Environment @(
        "ARTIFACTORY_PASSWORD=$token",
        "CONAN_REMOTE=$remote",
        "CONAN_USER=$($script:ArtifactoryAdminUser)"
    ) -AllowFailure
    if ($login.ExitCode -ne 0) {
        Stop-WithError "conan remote login failed for '$remote': $($login.Output)"
    }
    Write-Info "remote '$remote': logged in as '$($script:ArtifactoryAdminUser)'"
}

$remotesText = (Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'remote', 'list'
    )).Output
foreach ($remote in $script:ConanRemotes) {
    $url = "$($script:ArtifactoryNetworkUrl)/artifactory/api/conan/$remote"
    if ((Get-RemoteUrl -Text $remotesText -Name $remote) -ne $url) {
        Stop-WithError "remote '$remote' does not point to $url"
    }
}
Write-Info 'remote URLs verified'

$usersText = (Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'remote', 'list-users'
    )).Output
function Test-RemoteUser {
    param([string]$Text, [string]$Remote, [string]$User)
    $inRemote = $false
    $sawUser = $false
    $sawAuth = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match ('^' + [regex]::Escape($Remote) + ':\s*$')) {
            $inRemote = $true
            continue
        }
        if ($inRemote -and $line -match '^\S') { break }
        if ($inRemote) {
            if ($line -match ('Username:\s+' + [regex]::Escape($User))) { $sawUser = $true }
            if ($line -match 'authenticated:\s+True') { $sawAuth = $true }
        }
    }
    return ($sawUser -and $sawAuth)
}
foreach ($remote in $script:ConanRemotes) {
    if (-not (Test-RemoteUser -Text $usersText -Remote $remote -User $script:ArtifactoryAdminUser)) {
        Stop-WithError "remote '$remote' has no authenticated user '$($script:ArtifactoryAdminUser)'"
    }
}
Write-Info 'stored credentials verified for all remotes'

foreach ($remote in $script:ConanRemotes) {
    $access = Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'list', '*', "-r=$remote"
    ) -AllowFailure
    if ($access.ExitCode -ne 0) {
        Stop-WithError "authenticated access to remote '$remote' failed: $($access.Output)"
    }
    Write-Info "remote '$remote': authenticated API access OK"
}

Write-Log "Step 4/8: OK"
