# Bootstrap the local Gitea + Jenkins + Conan contour (Windows PowerShell).
# Idempotent: safe to rerun on an existing stack.
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $root

$secrets = Join-Path $root '.secrets'
if (-not (Test-Path -LiteralPath $secrets)) {
    New-Item -ItemType Directory -Path $secrets -Force | Out-Null
}
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $secrets /inheritance:r /grant:r "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' 2>&1 | Out-Null
} catch {
    Write-Warning "could not restrict ACL for ${secrets}: $($_.Exception.Message)"
}

$psExe = (Get-Process -Id $PID).Path
$steps = @(
    '00-wait-ready.ps1',
    '01-gitea-admin.ps1',
    '02-gitea-orgs-token.ps1',
    '03-conan-profile.ps1',
    '04-conan-remotes.ps1',
    '05-jenkins-admin.ps1',
    '06-jenkins-gitea.ps1',
    '07-smoke-test.ps1'
)

$started = Get-Date
foreach ($step in $steps) {
    Write-Host "`n########## $step ##########"
    & $psExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $step)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: step $step failed with exit code $LASTEXITCODE" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

Write-Host "`n########## 08-report.ps1 ##########"
& $psExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '08-report.ps1') 1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: report generation failed with exit code $LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
}

$elapsed = [int]((Get-Date) - $started).TotalSeconds
Write-Host "`nBootstrap finished in ${elapsed}s. Report: $(Join-Path $root 'SETUP-REPORT.md')"
exit 0
