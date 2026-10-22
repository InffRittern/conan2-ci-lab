# Step 7/8: end-to-end smoke test through the packages -> products -> develop flow.
. "$PSScriptRoot\lib.ps1"

Write-Log "Step 7/8: Conan smoke test"
Test-ContainerRunning -Container $script:ConanContainer

function Clear-SmokePackages {
    foreach ($remote in $script:ConanRemotes) {
        Invoke-Docker -DockerArgs @(
            'exec', $script:ConanContainer, 'conan', 'remove', 'smoke/*', "-r=$remote", '-c'
        ) -AllowFailure | Out-Null
    }
    Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'remove', 'smoke/*', '-c'
    ) -AllowFailure | Out-Null
}

# Leave no stale package behind if an earlier run failed midway.
Clear-SmokePackages

$recipe = @'
from conan import ConanFile


class SmokeConan(ConanFile):
    name = "smoke"
    version = "0.1.0"
    settings = "os", "arch", "compiler", "build_type"
'@

function Invoke-SmokeStep {
    param([string]$Label, [string[]]$Arguments)
    Write-Host "--- $Label"
    $result = Invoke-Docker -DockerArgs $Arguments -AllowFailure
    if ($result.ExitCode -ne 0) {
        Write-Host $result.Output
        Stop-WithError "smoke step '$Label' failed"
    }
    return $result.Output
}

function Assert-SmokeListed {
    param([string]$Remote)
    $result = Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'list', 'smoke/0.1.0:*', "-r=$Remote"
    ) -AllowFailure
    if ($result.ExitCode -ne 0 -or -not (Test-HasText $result.Output 'smoke/0.1.0')) {
        Write-Host $result.Output
        Stop-WithError "smoke/0.1.0 is not listed on remote '$Remote'"
    }
}

try {
    $workdir = '/tmp/conan-smoke'
    Invoke-Docker -DockerArgs @('exec', $script:ConanContainer, 'rm', '-rf', $workdir) | Out-Null
    Invoke-Docker -DockerArgs @('exec', $script:ConanContainer, 'mkdir', '-p', $workdir) | Out-Null
    $hostRecipe = New-TempFileWithText -Content $recipe
    try {
        Invoke-Docker -DockerArgs @(
            'cp', $hostRecipe, "$($script:ConanContainer):$workdir/conanfile.py"
        ) | Out-Null
    } finally {
        Remove-Item -LiteralPath $hostRecipe -Force -ErrorAction SilentlyContinue
    }

    Invoke-SmokeStep -Label 'conan create' -Arguments @(
        'exec', '-w', $workdir, $script:ConanContainer,
        'conan', 'create', '.', '-s', 'build_type=Release'
    ) | Out-Null

    Invoke-SmokeStep -Label 'upload to packages' -Arguments @(
        'exec', '-w', $workdir, $script:ConanContainer,
        'conan', 'upload', 'smoke/0.1.0:*', '-r=packages', '-c'
    ) | Out-Null
    Assert-SmokeListed -Remote 'packages'

    Invoke-SmokeStep -Label 'download back from packages' -Arguments @(
        'exec', '-w', $workdir, $script:ConanContainer,
        'conan', 'download', 'smoke/0.1.0:*', '-r=packages'
    ) | Out-Null

    foreach ($target in @('products', 'develop')) {
        Invoke-SmokeStep -Label "promote to $target" -Arguments @(
            'exec', '-w', $workdir, $script:ConanContainer,
            'conan', 'upload', 'smoke/0.1.0:*', "-r=$target", '-c'
        ) | Out-Null
        Assert-SmokeListed -Remote $target
    }

    Write-Host 'smoke: uploaded, listed and downloaded on packages/products/develop'
} finally {
    Clear-SmokePackages
}

foreach ($remote in $script:ConanRemotes) {
    $left = Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'list', 'smoke/*', "-r=$remote"
    ) -AllowFailure
    if (Test-HasText $left.Output 'smoke/0.1.0') {
        Stop-WithError "smoke package still present on remote '$remote' after cleanup"
    }
    Write-Info "remote '$remote': smoke package removed"
}

Write-Log "Step 7/8: OK (smoke package cleaned up)"
