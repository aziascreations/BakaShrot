# Builds everything (the server, the tools, the client library), release
# mode, into target\release\.
# Usage: powershell -ExecutionPolicy Bypass -File build.ps1
$ErrorActionPreference = "Stop"

# rustup's folder isn't always on the PATH (it isn't in every shell here).
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $env:PATH = (Join-Path $env:USERPROFILE ".cargo\bin") + [IO.Path]::PathSeparator + $env:PATH
}

Push-Location $PSScriptRoot
try {
    cargo build --workspace --release --locked
    if ($LASTEXITCODE -ne 0) { "FAILED: cargo build"; exit 1 }
} finally {
    Pop-Location
}
"Built into $(Join-Path $PSScriptRoot "target\release")"
exit 0
