# Step 0/8: wait until the compose services and the Conan sidecar are ready.
. "$PSScriptRoot\lib.ps1"

Write-Log "Step 0/8: waiting for Gitea, Jenkins and the Conan container"

$network = Invoke-Docker -DockerArgs @('network', 'inspect', $script:CiNetwork) -AllowFailure
if ($network.ExitCode -ne 0) {
    Stop-WithError "docker network '$($script:CiNetwork)' not found; start the stack with 'docker compose up -d'"
}

foreach ($container in @($script:GiteaContainer, $script:JenkinsContainer)) {
    Test-ContainerRunning -Container $container
    Write-Info "container '$container' is running"
}

$conanInspect = Invoke-Docker -DockerArgs @('inspect', '-f', '{{.State.Running}}', $script:ConanContainer) -AllowFailure
if ($conanInspect.ExitCode -ne 0) {
    Write-Info "creating Conan sidecar '$($script:ConanContainer)' ($($script:ConanImage)) on $($script:CiNetwork)"
    $created = Invoke-Docker -DockerArgs @(
        'run', '-d',
        '--name', $script:ConanContainer,
        '--hostname', $script:ConanContainer,
        '--network', $script:CiNetwork,
        '-v', "$($script:ConanVolume):/workspace",
        $script:ConanImage, 'sleep', 'infinity'
    )
    if ($created.ExitCode -ne 0) {
        Stop-WithError "failed to create Conan sidecar: $($created.Output)"
    }
} elseif ($conanInspect.Output.Trim() -ne 'true') {
    Write-Info "starting stopped Conan sidecar"
    $started = Invoke-Docker -DockerArgs @('start', $script:ConanContainer)
    if ($started.ExitCode -ne 0) {
        Stop-WithError "failed to start Conan sidecar: $($started.Output)"
    }
}
Test-ContainerRunning -Container $script:ConanContainer
$probe = Invoke-Docker -DockerArgs @('exec', $script:ConanContainer, 'true') -AllowFailure
if ($probe.ExitCode -ne 0) {
    Stop-WithError "container '$($script:ConanContainer)' cannot execute commands: $($probe.Output)"
}
Write-Info "container '$($script:ConanContainer)' is running"

Wait-Http -Container $script:GiteaContainer -Url "$($script:GiteaUrl)/api/healthz" -TimeoutSeconds 120 -Label 'Gitea'
Wait-Http -Container $script:JenkinsContainer -Url "$($script:JenkinsUrl)/login" -TimeoutSeconds 300 -Label 'Jenkins'

Write-Log "Step 0/8: OK"
