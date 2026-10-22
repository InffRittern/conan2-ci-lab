# Step 3/8: Conan toolchain and the default profile (gcc 13, C++17).
. "$PSScriptRoot\lib.ps1"

Write-Log "Step 3/8: Conan toolchain and profile"
Test-ContainerRunning -Container $script:ConanContainer

# The sidecar is a plain ubuntu image on first use.
$toolchainCheck = 'command -v gcc >/dev/null && command -v g++ >/dev/null && ' +
    'command -v cmake >/dev/null && command -v ninja >/dev/null && command -v git >/dev/null && ' +
    'command -v python3 >/dev/null && python3 -m pip --version >/dev/null 2>&1'
$toolchain = Invoke-ContainerShell -Container $script:ConanContainer `
    -Script $toolchainCheck -AllowFailure
if ($toolchain.ExitCode -ne 0) {
    Write-Info "installing build tools in '$($script:ConanContainer)'"
    $installScript = 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ' +
        '--no-install-recommends python3 python3-pip python3-venv gcc g++ cmake ninja-build git ' +
        'ca-certificates curl'
    $install = Invoke-ContainerShell -Container $script:ConanContainer `
        -Script $installScript -AllowFailure
    if ($install.ExitCode -ne 0) {
        Stop-WithError "failed to install build tools: $($install.Output)"
    }
}

function Get-ConanVersion {
    # docker writes OCI errors to stdout, so check the exit status first.
    $result = Invoke-Docker -DockerArgs @('exec', $script:ConanContainer, 'conan', '--version') -AllowFailure
    if ($result.ExitCode -ne 0) { return '' }
    $parts = @($result.Output.Trim() -split '\s+')
    if ($parts.Count -lt 3) { return '' }
    return $parts[2]
}

$conanVersion = Get-ConanVersion
if ([string]::IsNullOrEmpty($conanVersion) -or (Test-VersionLt -A $conanVersion -B '2.32')) {
    Write-Info "installing conan>=2.32 (found: $(if ($conanVersion) { $conanVersion } else { 'none' }))"
    $pip = Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'python3', '-m', 'pip', 'install',
        '--break-system-packages', '-q', 'conan>=2.32'
    ) -AllowFailure
    if ($pip.ExitCode -ne 0) {
        Stop-WithError "pip install conan failed: $($pip.Output)"
    }
    $conanVersion = Get-ConanVersion
    if ([string]::IsNullOrEmpty($conanVersion)) {
        Stop-WithError 'conan is still not runnable after pip install'
    }
}
if (Test-VersionLt -A $conanVersion -B '2.32') {
    Stop-WithError "Conan $conanVersion is older than 2.32"
}
Write-Info "conan $conanVersion"

$gccVersion = (Invoke-Docker -DockerArgs @('exec', $script:ConanContainer, 'gcc', '-dumpversion')).Output.Trim()
$gccMajor = ($gccVersion -split '\.')[0]
if ($gccMajor -ne '13') {
    Stop-WithError "expected gcc 13 in '$($script:ConanContainer)', found $gccMajor"
}
Write-Info "gcc $gccMajor"

$applyCppstd = 'f="$(conan config home)/profiles/default"; if grep -q "^compiler.cppstd=" "$f"; then sed -i "s/^compiler.cppstd=.*/compiler.cppstd=17/" "$f"; else printf "compiler.cppstd=17\n" >> "$f"; fi'

function Test-ConanProfile {
    $profile = Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'profile', 'show'
    ) -AllowFailure
    if ($profile.ExitCode -ne 0) { return $false }
    $lines = @($profile.Output -split "`r?`n" | ForEach-Object { $_.Trim() })
    return (($lines -contains 'compiler=gcc') -and
        ($lines -contains 'compiler.version=13') -and
        ($lines -contains 'compiler.cppstd=17'))
}

$profileFile = Invoke-ContainerShell -Container $script:ConanContainer `
    -Script 'test -f "$(conan config home)/profiles/default"' -AllowFailure
if ($profileFile.ExitCode -ne 0) {
    Write-Info 'detecting default Conan profile'
    Invoke-Docker -DockerArgs @('exec', $script:ConanContainer, 'conan', 'profile', 'detect', '--force') | Out-Null
}
Invoke-ContainerShell -Container $script:ConanContainer -Script $applyCppstd | Out-Null

if (-not (Test-ConanProfile)) {
    Write-Info 'profile does not match gcc/13/17; regenerating it'
    Invoke-Docker -DockerArgs @('exec', $script:ConanContainer, 'conan', 'profile', 'detect', '--force') | Out-Null
    Invoke-ContainerShell -Container $script:ConanContainer -Script $applyCppstd | Out-Null
}
if (-not (Test-ConanProfile)) {
    $shown = (Invoke-Docker -DockerArgs @(
            'exec', $script:ConanContainer, 'conan', 'profile', 'show'
        ) -AllowFailure).Output
    Stop-WithError "Conan default profile is not gcc/13/17: $shown"
}
Write-Info 'default profile: gcc 13, cppstd 17'

Write-Log "Step 3/8: OK"
