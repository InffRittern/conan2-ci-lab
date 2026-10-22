# Step 2/8: Gitea organizations and the Conan CI access token.
. "$PSScriptRoot\lib.ps1"

Write-Log "Step 2/8: Gitea organizations and API token"
Test-ContainerRunning -Container $script:GiteaContainer

if (-not (Test-Path -LiteralPath $script:SecretsDir)) {
    New-Item -ItemType Directory -Path $script:SecretsDir -Force | Out-Null
}
Set-SecretPermissions -Path $script:SecretsDir -Directory

# JSON payloads go through a file: PowerShell 5.1 corrupts embedded double
# quotes when passing a JSON string as a native argument.
function Invoke-GiteaAdminJson {
    param(
        [string]$Method,
        [string]$Url,
        [string]$Json,
        [switch]$OnlyStatus
    )
    $hostFile = New-TempFileWithText -Content $Json
    $remote = "/tmp/gitea-payload-" + [guid]::NewGuid().ToString('N') + ".json"
    try {
        Invoke-Docker -DockerArgs @('cp', $hostFile, "$($script:GiteaContainer):$remote") | Out-Null
        $curlArgs = @(
            '-X', $Method,
            '-H', 'Content-Type: application/json',
            '--data-binary', "@$remote"
        )
        if ($OnlyStatus) {
            $curlArgs += @('-s', '-o', '/dev/null', '-w', '%{http_code}')
        }
        $curlArgs += $Url
        return Invoke-GiteaAdminCurl $curlArgs
    } finally {
        Invoke-Docker -DockerArgs @(
            'exec', $script:GiteaContainer, 'rm', '-f', $remote
        ) -AllowFailure | Out-Null
        Remove-Item -LiteralPath $hostFile -Force -ErrorAction SilentlyContinue
    }
}

# 01 must have produced a working admin.
if ((Get-GiteaAdminStatus -Url "$($script:GiteaUrl)/api/v1/user") -ne '200') {
    Stop-WithError "Gitea admin '$($script:GiteaAdminUser)' is not usable; run 01-gitea-admin.ps1 first"
}

foreach ($org in $script:ConanRemotes) {
    $code = Get-GiteaAdminStatus -Url "$($script:GiteaUrl)/api/v1/orgs/$org"
    if ($code -eq '200') {
        Write-Info "organization '$org' already exists"
        continue
    }
    if ($code -ne '404') {
        Stop-WithError "unexpected GET /orgs/$org`: HTTP $code"
    }

    $payload = @{ username = $org; visibility = 'public' } | ConvertTo-Json -Compress
    $code = (Invoke-GiteaAdminJson -Method 'POST' -Url "$($script:GiteaUrl)/api/v1/orgs" `
            -Json $payload -OnlyStatus).Trim()
    switch ($code) {
        '201' { Write-Info "organization '$org' created" }
        '422' { Write-Info "organization '$org' already exists (422)" }
        default { Stop-WithError "failed to create organization '$org' (HTTP $code)" }
    }
    if ((Get-GiteaAdminStatus -Url "$($script:GiteaUrl)/api/v1/orgs/$org") -ne '200') {
        Stop-WithError "organization '$org' is not readable after creation"
    }
}

# Reuse the saved token only if Gitea still accepts it.
$token = ''
if ((Test-Path -LiteralPath $script:GiteaTokenFile) -and
    (Get-Item -LiteralPath $script:GiteaTokenFile).Length -gt 0) {
    $candidate = (Get-Content -Raw -LiteralPath $script:GiteaTokenFile).Trim()
    $code = (Invoke-GiteaCurl @(
            '-s', '-o', '/dev/null', '-w', '%{http_code}',
            '-H', "Authorization: token $candidate",
            "$($script:GiteaUrl)/api/v1/user"
        )).Trim()
    if ($code -eq '200') {
        $token = $candidate
        Write-Info "reusing token from $($script:GiteaTokenFile)"
    } else {
        Write-Info "saved token is no longer valid (HTTP $code); creating a new one"
    }
}

if ([string]::IsNullOrEmpty($token)) {
    # Remove stale tokens with the same name so reruns do not accumulate them.
    $tokensJson = Invoke-GiteaAdminCurl @("$($script:GiteaUrl)/api/v1/users/$($script:GiteaAdminUser)/tokens")
    $tokenList = @()
    try { $tokenList = @($tokensJson | ConvertFrom-Json) } catch { $tokenList = @() }
    foreach ($entry in $tokenList) {
        if ($entry.name -ne 'conan-ci') { continue }
        $id = $entry.id
        $code = (Invoke-GiteaAdminCurl @(
                '-s', '-o', '/dev/null', '-w', '%{http_code}', '-X', 'DELETE',
                "$($script:GiteaUrl)/api/v1/users/$($script:GiteaAdminUser)/tokens/$id"
            )).Trim()
        if ($code -ne '204') {
            Stop-WithError "failed to delete old token id=$id (HTTP $code)"
        }
        Write-Info "deleted old token id=$id"
    }

    $scopes = @(
        'write:organization', 'read:organization',
        'read:user', 'read:repository', 'write:repository'
    )
    $payload = @{ name = 'conan-ci'; scopes = $scopes } | ConvertTo-Json -Compress
    $response = Invoke-GiteaAdminJson -Method 'POST' `
        -Url "$($script:GiteaUrl)/api/v1/users/$($script:GiteaAdminUser)/tokens" -Json $payload
    $token = ''
    try { $token = ($response | ConvertFrom-Json).sha1 } catch { $token = '' }
    if ([string]::IsNullOrEmpty($token) -or $token -notmatch '^[0-9a-f]{40,}$') {
        Stop-WithError "Gitea did not return a valid token: $response"
    }

    [IO.File]::WriteAllText($script:GiteaTokenFile, $token, (New-Object System.Text.UTF8Encoding($false)))
    Set-SecretPermissions -Path $script:GiteaTokenFile
    Write-Info "created token 'conan-ci' and saved it to $($script:GiteaTokenFile)"
}

if ([string]::IsNullOrEmpty($token)) { Stop-WithError 'empty Gitea token' }
$code = (Invoke-GiteaCurl @(
        '-s', '-o', '/dev/null', '-w', '%{http_code}',
        '-H', "Authorization: token $token",
        "$($script:GiteaUrl)/api/v1/user"
    )).Trim()
if ($code -ne '200') { Stop-WithError "token verification failed (HTTP $code)" }
Write-Info "token authenticates against the Gitea API"

Write-Log "Step 2/8: OK"
