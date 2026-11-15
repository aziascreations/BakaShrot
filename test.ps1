# Runs what CI runs (.github/workflows/ci.yml), in this order:
# formatting, clippy (warnings are errors), the tests, the docs.
# Exit code 0 when everything passed.
# Usage: powershell -ExecutionPolicy Bypass -File test.ps1
$ErrorActionPreference = "Stop"

# rustup's folder isn't always on the PATH (it isn't in every shell here).
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $env:PATH = (Join-Path $env:USERPROFILE ".cargo\bin") + [IO.Path]::PathSeparator + $env:PATH
}

function Step([string]$What, [scriptblock]$Run) {
    "== $What"
    & $Run
    if ($LASTEXITCODE -ne 0) { "FAILED: $What"; exit 1 }
}

Push-Location $PSScriptRoot
try {
    Step "cargo fmt" { cargo fmt --all -- --check }
    Step "cargo clippy" { cargo clippy --locked --workspace --all-targets --all-features -- -D warnings }
    Step "cargo test" { cargo test --locked --workspace --all-features }
    $env:RUSTDOCFLAGS = "-D warnings"
    Step "cargo doc" { cargo doc --locked --workspace --no-deps --all-features }
} finally {
    Pop-Location
}
"All checks passed"
exit 0
