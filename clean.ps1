# Deletes what the builds and releases made: target\ (cargo's output and
# target\dist\), and Python's __pycache__ folders.
# Usage: powershell -ExecutionPolicy Bypass -File clean.ps1
$ErrorActionPreference = "Stop"

# rustup's folder isn't always on the PATH (it isn't in every shell here).
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $env:PATH = (Join-Path $env:USERPROFILE ".cargo\bin") + [IO.Path]::PathSeparator + $env:PATH
}

Push-Location $PSScriptRoot
try {
    cargo clean
    if ($LASTEXITCODE -ne 0) { "FAILED: cargo clean"; exit 1 }
    Get-ChildItem -Path bindings -Directory -Recurse -Filter __pycache__ | Remove-Item -Recurse -Force
} finally {
    Pop-Location
}
"Cleaned"
exit 0
