# Step 1/8: Gitea admin user and required Gitea settings.
. "$PSScriptRoot\lib.ps1"

Write-Log "Step 1/8: Gitea admin user and settings"
Test-ContainerRunning -Container $script:GiteaContainer
Wait-Http -Container $script:GiteaContainer -Url "$($script:GiteaUrl)/api/healthz" -TimeoutSeconds 120 -Label 'Gitea'

function Assert-GiteaAdmin {
    $body = Invoke-GiteaAdminCurl @("$($script:GiteaUrl)/api/v1/user")
    if (-not (Test-HasText $body ('"login":"' + $script:GiteaAdminUser + '"'))) {
        Stop-WithError "Gitea API did not return the admin login: $body"
    }
    if (-not (Test-HasText $body '"is_admin":true')) {
        Stop-WithError "user '$($script:GiteaAdminUser)' is not a Gitea administrator: $body"
    }
    Write-Info "admin '$($script:GiteaAdminUser)' authenticates and is_admin=true"
}

$adminCode = Get-GiteaAdminStatus -Url "$($script:GiteaUrl)/api/v1/user"
if ($adminCode -eq '200') {
    Write-Info "admin '$($script:GiteaAdminUser)' already exists with the configured password"
} else {
    $userCode = (Invoke-GiteaCurl @(
            '-s', '-o', '/dev/null', '-w', '%{http_code}',
            "$($script:GiteaUrl)/api/v1/users/$($script:GiteaAdminUser)"
        )).Trim()

    if ($userCode -eq '200') {
        Write-Info "admin exists but the password check failed (HTTP $adminCode); resetting password"
        $result = Invoke-Docker -DockerArgs @(
            'exec', '-u', 'git', $script:GiteaContainer, 'gitea', 'admin', 'user', 'change-password',
            '--username', $script:GiteaAdminUser,
            '--password', $script:GiteaAdminPassword
        ) -AllowFailure
        if ($result.ExitCode -ne 0) {
            Stop-WithError "gitea admin user change-password failed: $($result.Output)"
        }
    } elseif ($userCode -eq '404') {
        Write-Info "creating Gitea admin '$($script:GiteaAdminUser)'"
        $result = Invoke-Docker -DockerArgs @(
            'exec', '-u', 'git', $script:GiteaContainer, 'gitea', 'admin', 'user', 'create',
            '--username', $script:GiteaAdminUser,
            '--password', $script:GiteaAdminPassword,
            '--email', $script:GiteaAdminEmail,
            '--admin', '--must-change-password=false'
        ) -AllowFailure
        if ($result.ExitCode -ne 0) {
            Stop-WithError "gitea admin user create failed: $($result.Output)"
        }
    } else {
        Stop-WithError "unexpected Gitea user lookup result for '$($script:GiteaAdminUser)': HTTP $userCode"
    }

    # Gitea always marks the password as must-change after change-password.
    $result = Invoke-Docker -DockerArgs @(
        'exec', '-u', 'git', $script:GiteaContainer, 'gitea', 'admin', 'user',
        'must-change-password', '--unset', $script:GiteaAdminUser
    ) -AllowFailure
    if ($result.ExitCode -ne 0) {
        Stop-WithError "failed to clear must-change-password for '$($script:GiteaAdminUser)': $($result.Output)"
    }
    Write-Info "must-change-password is disabled for '$($script:GiteaAdminUser)'"
}

Assert-GiteaAdmin

# Gitea is the source repository only. Keep the package registry disabled even
# if an older stack left it enabled in app.ini.
$restartGitea = $false
try {
    if (Set-GiteaIni -Section 'packages' -Key 'ENABLED' -Value 'false') {
        Write-Info "app.ini: wrote [packages] ENABLED = false"
        $restartGitea = $true
    } else {
        Write-Info "app.ini: [packages] ENABLED = false"
    }
} catch {
    Stop-WithError "failed to update [packages] in app.ini: $($_.Exception.Message)"
}

# Gitea only allows webhooks to hosts listed here (or '*').
$iniText = (Invoke-Docker -DockerArgs @(
        'exec', $script:GiteaContainer, 'cat', '/data/gitea/conf/app.ini'
    )).Output
$allowed = Get-IniValue -Content $iniText -Section 'security' -Key 'ALLOWED_HOST_LIST'
$allowedNew = $allowed
if ([string]::IsNullOrEmpty($allowed)) {
    $allowedNew = 'jenkins'
} else {
    $entries = @($allowed -split ',' | ForEach-Object { $_.Trim() })
    if (($entries -contains '*') -or ($entries -contains 'jenkins')) {
        $allowedNew = $allowed
    } else {
        $allowedNew = "$allowed,jenkins"
    }
}
if ($allowedNew -ne $allowed) {
    try {
        if (Set-GiteaIni -Section 'security' -Key 'ALLOWED_HOST_LIST' -Value $allowedNew) {
            Write-Info "app.ini: ALLOWED_HOST_LIST = $allowedNew"
            $restartGitea = $true
        }
    } catch {
        Stop-WithError "failed to update ALLOWED_HOST_LIST: $($_.Exception.Message)"
    }
} else {
    Write-Info "app.ini: ALLOWED_HOST_LIST allows jenkins ($allowed)"
}

if ($restartGitea) {
    Write-Info "restarting Gitea to apply app.ini changes"
    Invoke-Docker -DockerArgs @('restart', $script:GiteaContainer) | Out-Null
    Wait-Http -Container $script:GiteaContainer -Url "$($script:GiteaUrl)/api/healthz" -TimeoutSeconds 120 -Label 'Gitea'
    Assert-GiteaAdmin
}

Write-Log "Step 1/8: OK"
