# Entry point for the Windows (PowerShell) variant. See scripts/windows/.
& (Join-Path $PSScriptRoot 'scripts\windows\bootstrap.ps1') @args
exit $LASTEXITCODE
