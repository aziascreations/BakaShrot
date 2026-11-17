# A release for this platform, built, packaged and smoke-tested, into
# target\dist\ (release.py, Python 3.11+, does it all).
# Usage: powershell -ExecutionPolicy Bypass -File release.ps1 [-SkipTest] [-HybridCrt]
# (-HybridCrt: the UCRT from Windows, see release.py's --hybrid-crt)
param([switch]$SkipTest, [switch]$HybridCrt)
$ErrorActionPreference = "Stop"

# The py launcher if it's there, python otherwise.
$python = if (Get-Command py -ErrorAction SilentlyContinue) { @("py", "-3") } else { @("python") }
$arguments = @(Join-Path $PSScriptRoot "release.py")
if ($SkipTest) { $arguments += "--skip-test" }
if ($HybridCrt) { $arguments += "--hybrid-crt" }
& $python[0] @($python | Select-Object -Skip 1) @arguments
exit $LASTEXITCODE
