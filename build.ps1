# Builds everything (the server, the tool, the client library), release
# mode, into target\release\: the tool with its own profile (release-tools,
# Cargo.toml) in target\release-tools\, then copied beside the others.
# -HybridCrt: the UCRT from Windows instead of linked in, about 180 KB less
# per program (.cargo/hybrid-crt.toml).
# Usage: powershell -ExecutionPolicy Bypass -File build.ps1 [-HybridCrt]
param([switch]$HybridCrt)
$ErrorActionPreference = "Stop"
$crt = if ($HybridCrt) { @("--config", ".cargo/hybrid-crt.toml") } else { @() }

# rustup's folder isn't always on the PATH (it isn't in every shell here).
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $env:PATH = (Join-Path $env:USERPROFILE ".cargo\bin") + [IO.Path]::PathSeparator + $env:PATH
}

Push-Location $PSScriptRoot
try {
    cargo build --workspace --exclude bakashrot-tools --release --locked @crt
    if ($LASTEXITCODE -ne 0) { "FAILED: cargo build"; exit 1 }
    cargo build -p bakashrot-tools --profile release-tools --locked @crt
    if ($LASTEXITCODE -ne 0) { "FAILED: cargo build (the tool)"; exit 1 }
    $tool = if ($IsLinux -or $IsMacOS) { "bakashrot" } else { "bakashrot.exe" }
    Copy-Item (Join-Path "target\release-tools" $tool) "target\release" -Force
} finally {
    Pop-Location
}
"Built into $(Join-Path $PSScriptRoot "target\release")"
exit 0
