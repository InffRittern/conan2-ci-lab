# Shared environment and helpers for the Windows PowerShell variant.
# Every step script dot-sources this file.

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch {
    # Older hosts may refuse the console encoding change; commands are ASCII.
}

$script:ScriptDir = $PSScriptRoot
$script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# Optional local overrides. The file is ignored by Git; see .env.example.
$envFile = Join-Path $script:RootDir '.env'
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        $index = $line.IndexOf('=')
        if ($index -lt 1) { return }
        $name = $line.Substring(0, $index).Trim()
        $value = $line.Substring($index + 1).Trim()
        if ($value.Length -ge 2 -and (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

function Get-EnvOrDefault {
    param([string]$Name, [string]$Default)
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    return $value
}

$script:GiteaContainer = Get-EnvOrDefault 'GITEA_CONTAINER' 'gitea'
$script:JenkinsContainer = Get-EnvOrDefault 'JENKINS_CONTAINER' 'jenkins'
$script:ConanContainer = Get-EnvOrDefault 'CONAN_CONTAINER' 'conan'
$script:ConanImage = Get-EnvOrDefault 'CONAN_IMAGE' 'ubuntu:24.04'
$script:ConanVolume = Get-EnvOrDefault 'CONAN_VOLUME' 'conan_workspace'
$script:ComposeProjectName = Get-EnvOrDefault 'COMPOSE_PROJECT_NAME' (Split-Path -Leaf $script:RootDir)
$script:CiNetwork = Get-EnvOrDefault 'CI_NETWORK' "$($script:ComposeProjectName)_ci_network"

$script:GiteaAdminUser = Get-EnvOrDefault 'GITEA_ADMIN_USER' 'admin'
$script:GiteaAdminPassword = Get-EnvOrDefault 'GITEA_ADMIN_PASSWORD' 'password'
$script:GiteaAdminEmail = Get-EnvOrDefault 'GITEA_ADMIN_EMAIL' 'admin@example.com'
$script:GiteaUrl = Get-EnvOrDefault 'GITEA_URL' 'http://localhost:3000'
$script:GiteaNetworkUrl = Get-EnvOrDefault 'GITEA_NETWORK_URL' 'http://gitea:3000'
$script:ArtifactoryUrl = Get-EnvOrDefault 'ARTIFACTORY_URL' 'http://localhost:8082'
$script:ArtifactoryNetworkUrl = Get-EnvOrDefault 'ARTIFACTORY_NETWORK_URL' 'http://artifactory:8082'
$script:ArtifactoryAdminUser = Get-EnvOrDefault 'ARTIFACTORY_ADMIN_USER' 'admin'
$script:ArtifactoryAdminPassword = Get-EnvOrDefault 'ARTIFACTORY_ADMIN_PASSWORD' (Get-EnvOrDefault 'ARTIFACTORY_PASSWORD' 'password')

$script:JenkinsAdminUser = Get-EnvOrDefault 'JENKINS_ADMIN_USER' 'admin'
$script:JenkinsAdminPassword = Get-EnvOrDefault 'JENKINS_ADMIN_PASSWORD' 'password'
$script:JenkinsUrl = Get-EnvOrDefault 'JENKINS_URL' 'http://localhost:8080'

$script:ConanRemotes = @('packages', 'products', 'develop')
$script:JenkinsPlugins = @(
    'gitea',
    'docker-workflow',
    'workflow-aggregator',
    'git',
    'pipeline-stage-view'
)

$script:SecretsDir = Join-Path $script:RootDir '.secrets'
$script:GiteaTokenFile = Join-Path $script:SecretsDir 'gitea-token'
$script:JenkinsPassFile = Join-Path $script:SecretsDir 'jenkins-pass'
$script:JenkinsAuth = @()

function Write-Log {
    param([string]$Message)
    Write-Host "`n==> $Message"
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message"
}

function Stop-WithError {
    param([string]$Message)
    Write-Host "`nERROR: $Message" -ForegroundColor Red
    exit 1
}

# Runs docker and captures stdout+stderr. Returns Output and ExitCode.
function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)][string[]]$DockerArgs,
        [string]$InputText,
        [switch]$AllowFailure
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $output = $InputText | & docker @DockerArgs 2>&1
        } else {
            $output = & docker @DockerArgs 2>&1
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    $lines = @()
    foreach ($item in $output) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            $lines += $item.ToString()
        } else {
            $lines += [string]$item
        }
    }
    $text = $lines -join "`n"

    if ($code -ne 0 -and -not $AllowFailure) {
        throw "docker $($DockerArgs -join ' ') failed with exit code $code`n$text"
    }
    return [pscustomobject]@{ Output = $text; ExitCode = $code }
}

function Test-ContainerRunning {
    param([string]$Container)
    $result = Invoke-Docker -DockerArgs @('inspect', '-f', '{{.State.Running}}', $Container) -AllowFailure
    if ($result.ExitCode -ne 0 -or $result.Output.Trim() -ne 'true') {
        Stop-WithError "container '$Container' is not running"
    }
}

# Runs a shell script inside a container from a copied file. PowerShell 5.1
# mangles embedded double quotes in native arguments and writes CRLF to stdin,
# so shell snippets are neither passed via -c nor piped.
function Invoke-ContainerShell {
    param(
        [string]$Container,
        [string]$Script,
        [string[]]$Environment = @(),
        [switch]$AllowFailure
    )
    $hostFile = New-TempFileWithText -Content ($Script.TrimEnd() + "`n")
    $remote = "/tmp/omp-shell-" + [guid]::NewGuid().ToString('N') + ".sh"
    try {
        Invoke-Docker -DockerArgs @('cp', $hostFile, "$($Container):$remote") | Out-Null
        $dockerArgs = @('exec')
        foreach ($item in $Environment) { $dockerArgs += @('-e', $item) }
        $dockerArgs += @($Container, 'bash', $remote)
        return Invoke-Docker -DockerArgs $dockerArgs -AllowFailure:$AllowFailure
    } finally {
        Invoke-Docker -DockerArgs @('exec', $Container, 'rm', '-f', $remote) -AllowFailure | Out-Null
        Remove-Item -LiteralPath $hostFile -Force -ErrorAction SilentlyContinue
    }
}

function Wait-Http {
    param(
        [string]$Container,
        [string]$Url,
        [int]$TimeoutSeconds,
        [string]$Label
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $probe = Invoke-Docker -DockerArgs @('exec', $Container, 'curl', '-fsS', '-o', '/dev/null', $Url) -AllowFailure
        if ($probe.ExitCode -eq 0) {
            Write-Info "$Label is ready ($Url)"
            return
        }
        Start-Sleep -Seconds 2
    }
    $code = (Invoke-Docker -DockerArgs @(
            'exec', $Container, 'curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}', $Url
        ) -AllowFailure).Output.Trim()
    if ([string]::IsNullOrEmpty($code)) { $code = 'no response' }
    Stop-WithError "$Label did not become ready at $Url within ${TimeoutSeconds}s (last HTTP code: $code)"
}

function Invoke-GiteaCurl {
    param([string[]]$CurlArgs)
    return (Invoke-Docker -DockerArgs (@('exec', $script:GiteaContainer, 'curl', '-sS') + $CurlArgs)).Output
}

function Invoke-GiteaAdminCurl {
    param([string[]]$CurlArgs)
    $auth = @('-u', "$($script:GiteaAdminUser):$($script:GiteaAdminPassword)")
    return (Invoke-Docker -DockerArgs (@('exec', $script:GiteaContainer, 'curl', '-sS') + $auth + $CurlArgs)).Output
}

function Get-GiteaAdminStatus {
    param([string]$Url)
    $curlArgs = @(
        'exec', $script:GiteaContainer, 'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
        '-u', "$($script:GiteaAdminUser):$($script:GiteaAdminPassword)", $Url
    )
    return (Invoke-Docker -DockerArgs $curlArgs).Output.Trim()
}

function Test-JenkinsAuth {
    $script:JenkinsAuth = @()
    if (Test-Path -LiteralPath $script:JenkinsPassFile) {
        $password = (Get-Content -Raw -LiteralPath $script:JenkinsPassFile).Trim()
        if (-not [string]::IsNullOrEmpty($password)) {
            $probe = Invoke-Docker -DockerArgs @(
                'exec', $script:JenkinsContainer, 'curl', '-fsS', '-o', '/dev/null',
                '-u', "$($script:JenkinsAdminUser):$password",
                "$($script:JenkinsUrl)/whoAmI/api/json"
            ) -AllowFailure
            if ($probe.ExitCode -eq 0) {
                $script:JenkinsAuth = @('-u', "$($script:JenkinsAdminUser):$password")
                return $true
            }
        }
    }
    $code = (Invoke-Docker -DockerArgs @(
            'exec', $script:JenkinsContainer, 'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
            "$($script:JenkinsUrl)/whoAmI/api/json"
        ) -AllowFailure).Output.Trim()
    return ($code -eq '200')
}

function Get-JenkinsPluginJson {
    $curlArgs = @('exec', $script:JenkinsContainer, 'curl', '-sg') + $script:JenkinsAuth + @(
        "$($script:JenkinsUrl)/pluginManager/api/json?tree=plugins[shortName,active]"
    )
    return (Invoke-Docker -DockerArgs $curlArgs).Output
}

function New-TempFileWithText {
    param([string]$Content)
    $path = Join-Path ([IO.Path]::GetTempPath()) ("omp-" + [guid]::NewGuid().ToString('N') + ".tmp")
    [IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Invoke-JenkinsScriptText {
    param([string]$Path)
    $crumbResult = Invoke-Docker -DockerArgs (@(
            'exec', $script:JenkinsContainer, 'curl', '-sS'
        ) + $script:JenkinsAuth + @(
            '-c', '/tmp/jenkins-bootstrap.cookies',
            "$($script:JenkinsUrl)/crumbIssuer/api/json"
        ))
    $crumb = $null
    try { $crumb = ($crumbResult.Output | ConvertFrom-Json).crumb } catch { $crumb = $null }
    if ([string]::IsNullOrEmpty($crumb)) {
        Stop-WithError "could not obtain a Jenkins CSRF crumb: $($crumbResult.Output)"
    }

    $remote = "/tmp/jenkins-script-" + [guid]::NewGuid().ToString('N') + ".groovy"
    Invoke-Docker -DockerArgs @('cp', $Path, "$($script:JenkinsContainer):$remote") | Out-Null
    try {
        $postArgs = @(
            'exec', $script:JenkinsContainer, 'curl', '-sS'
        ) + $script:JenkinsAuth + @(
            '-b', '/tmp/jenkins-bootstrap.cookies',
            '-H', "Jenkins-Crumb: $crumb",
            '-X', 'POST', '--data-urlencode', "script@$remote",
            "$($script:JenkinsUrl)/scriptText"
        )
        return (Invoke-Docker -DockerArgs $postArgs).Output
    } finally {
        Invoke-Docker -DockerArgs @('exec', $script:JenkinsContainer, 'rm', '-f', $remote) -AllowFailure | Out-Null
    }
}

function Test-VersionLt {
    param([string]$A, [string]$B)
    if ($A -eq $B) { return $false }
    return ([version]$A -lt [version]$B)
}

function Test-HasText {
    param([string]$Text, [string]$Pattern)
    if ($null -eq $Text) { return $false }
    return $Text.Contains($Pattern)
}

function ConvertTo-GroovySingleQuoted {
    param([string]$Value)
    return $Value.Replace('\', '\\').Replace("'", "\'")
}

function Get-IniValue {
    param([string]$Content, [string]$Section, [string]$Key)
    $lines = $Content -split "`r?`n"
    $inSection = $false
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*)$'
    foreach ($line in $lines) {
        if ($line -eq "[$Section]") { $inSection = $true; continue }
        if ($line -match '^\[') { $inSection = $false; continue }
        if ($inSection -and $line -match $keyPattern) {
            return $Matches[1].Trim()
        }
    }
    return ''
}

# Returns Text (rewritten) and Changed for one key inside one section.
function Set-IniValue {
    param([string]$Content, [string]$Section, [string]$Key, [string]$Value)
    $eol = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsWithNewline = $Content.EndsWith("`n")
    $body = $Content
    if ($endsWithNewline) {
        $body = $body.Substring(0, $body.Length - 1)
        if ($body.EndsWith("`r")) { $body = $body.Substring(0, $body.Length - 1) }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($body.Length -gt 0) {
        foreach ($line in $body.Split([string[]]@($eol), [StringSplitOptions]::None)) {
            [void]$lines.Add($line)
        }
    }

    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "[$Section]") { $start = $i; break }
    }

    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    if ($start -lt 0) {
        if ($lines.Count -gt 0) { [void]$lines.Add('') }
        [void]$lines.Add("[$Section]")
        [void]$lines.Add("$Key = $Value")
    } else {
        $end = $lines.Count
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\[') { $end = $i; break }
        }
        $keyIndex = -1
        for ($i = $start + 1; $i -lt $end; $i++) {
            if ($lines[$i] -match $keyPattern) { $keyIndex = $i; break }
        }
        if ($keyIndex -ge 0) {
            $lines[$keyIndex] = "$Key = $Value"
        } else {
            $lines.Insert($end, "$Key = $Value")
        }
    }

    $newText = ($lines -join $eol)
    if ($endsWithNewline -or $lines.Count -gt 0) { $newText += $eol }
    return [pscustomobject]@{ Text = $newText; Changed = ($newText -ne $Content) }
}

# Returns $true when app.ini was rewritten.
function Set-GiteaIni {
    param([string]$Section, [string]$Key, [string]$Value)
    $file = '/data/gitea/conf/app.ini'
    $before = (Invoke-Docker -DockerArgs @('exec', $script:GiteaContainer, 'cat', $file)).Output
    if (-not $before.EndsWith("`n")) { $before += "`n" }
    $update = Set-IniValue -Content $before -Section $Section -Key $Key -Value $Value
    if (-not $update.Changed) { return $false }

    $hostFile = New-TempFileWithText -Content $update.Text
    $remote = "/tmp/app.ini." + [guid]::NewGuid().ToString('N')
    try {
        Invoke-Docker -DockerArgs @('cp', $hostFile, "$($script:GiteaContainer):$remote") | Out-Null
        Invoke-Docker -DockerArgs @(
            'exec', '-u', 'git', $script:GiteaContainer, 'sh', '-c',
            "cat $remote > $file"
        ) | Out-Null
    } finally {
        Invoke-Docker -DockerArgs @('exec', $script:GiteaContainer, 'rm', '-f', $remote) -AllowFailure | Out-Null
        Remove-Item -LiteralPath $hostFile -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Set-SecretPermissions {
    param([string]$Path, [switch]$Directory)
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($Directory) {
            $grant = "${identity}:(OI)(CI)F"
            $system = 'SYSTEM:(OI)(CI)F'
        } else {
            $grant = "${identity}:F"
            $system = 'SYSTEM:F'
        }
        & icacls $Path /inheritance:r /grant:r $grant $system 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "icacls exited with code $LASTEXITCODE"
        }
    } catch {
        Write-Warning "could not restrict ACL for ${Path}: $($_.Exception.Message)"
    }
}
