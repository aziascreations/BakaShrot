# Runs the benchmarks, release mode: the tests ignored by default.
#   push         pushes through one server, 10 clients (end_to_end.rs, push_rate)
#   replication  4 servers in a Y, pushed to flat out (end_to_end.rs, replication_rate)
#   storage      the storage alone, the old storage's workload (storage.rs, compare_with_old)
# docs/server.md and docs/storage.md have the numbers measured so far.
# Usage: powershell -ExecutionPolicy Bypass -File bench.ps1 [-Only push,replication,storage] [-Sync full|normal]
# -Sync sets SQLite's synchronous for all of them (otherwise each one's
# default: full for push and replication, normal for storage). The tests'
# other variables are taken from the environment as they are: PUSHES and
# CLIENTS (push), NODES, SECONDS and BATCH (replication), PUSHES (storage).
param(
    [ValidateSet("push", "replication", "storage")]
    [string[]]$Only = @("push", "replication", "storage"),
    [ValidateSet("full", "normal")]
    [string]$Sync
)
$ErrorActionPreference = "Stop"

# rustup's folder isn't always on the PATH (it isn't in every shell here).
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $env:PATH = (Join-Path $env:USERPROFILE ".cargo\bin") + [IO.Path]::PathSeparator + $env:PATH
}

# What -Only names, in this order: the package, the test file, the test.
$benches = [ordered]@{
    push        = @("bakashrot-server", "end_to_end", "push_rate")
    replication = @("bakashrot-server", "end_to_end", "replication_rate")
    storage     = @("bakashrot-storage", "storage", "compare_with_old")
}

$oldSync = $env:SYNC
if ($Sync) { $env:SYNC = $Sync }
Push-Location $PSScriptRoot
try {
    foreach ($name in $benches.Keys) {
        if ($Only -notcontains $name) { continue }
        $package, $file, $test = $benches[$name]
        "== $name ($test)"
        cargo test --locked --release -p $package --test $file $test -- --ignored --exact --nocapture
        if ($LASTEXITCODE -ne 0) { "FAILED: $name"; exit 1 }
    }
} finally {
    Pop-Location
    $env:SYNC = $oldSync
}
"Benchmarks done"
exit 0
