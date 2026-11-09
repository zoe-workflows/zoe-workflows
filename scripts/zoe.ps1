#!/usr/bin/env pwsh
# PowerShell entry point. The locating logic lives in zoe.cmd so both shells
# behave identically; this wrapper only forwards and preserves the exit code.
#
# The error document goes to stdout, matching zoe.cmd, zoe.sh and the runtime
# (which prints success and failure through one channel).
$ErrorActionPreference = "Stop"
$cmd = Join-Path $PSScriptRoot "zoe.cmd"
if (-not (Test-Path -LiteralPath $cmd)) {
    Write-Output '{"error":{"code":"RUNTIME_NOT_FOUND","message":"scripts/zoe.cmd is missing next to this wrapper"}}'
    exit 126
}
& $cmd @args
exit $LASTEXITCODE
