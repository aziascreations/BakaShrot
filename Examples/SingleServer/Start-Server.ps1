# ============================================================================
# BakaShrot example: starts the server with server.ini.
#
# In a window of its own by default (the server needs a console: it reads
# its commands there, and stops at once without one), then waits until it
# listens. Type "quit" in that window to stop it, "help" for the others.
#
# Usage: powershell -ExecutionPolicy Bypass -File Start-Server.ps1 [-BinDir <dir>] [-Here] [-Reset]
#   -BinDir  Where BakaShrot_Server.exe is, with libsodium.dll and
#            sqlite3.dll: Build\ by default (Build.ps1), or a Release\<v>\.
#   -Here    Runs it in this console instead, until "quit".
#   -Reset   Deletes the example's database first: no messages, ids from 1.
#
# Its database, example.sqlite, goes next to this script.
# ============================================================================

param(
    [string]$BinDir = (Join-Path $PSScriptRoot "..\..\Build"),
    [switch]$Here,
    [switch]$Reset
)

$ErrorActionPreference = "Stop"

$Server = Join-Path $BinDir "BakaShrot_Server.exe"
$Ini    = Join-Path $PSScriptRoot "server.ini"
$Port   = 12360

function Test-Port($Port) {
    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Async = $Client.BeginConnect("127.0.0.1", $Port, $null, $null)
        return ($Async.AsyncWaitHandle.WaitOne(200) -and $Client.Connected)
    } catch { return $false }
    finally { $Client.Close() }
}

if (-not (Test-Path $Server)) {
    throw "No ${Server}: build it first (Build.ps1), or pass -BinDir"
}
if (Test-Port $Port) {
    throw "Something already listens on port $Port, the example server may already run"
}

if ($Reset) {
    Get-ChildItem $PSScriptRoot -Filter "example.sqlite*" | Remove-Item -Confirm:$false
    Write-Host "Deleted the example's database"
}

if ($Here) {
    Push-Location $PSScriptRoot
    try { & $Server $Ini }
    finally { Pop-Location }
    exit $LASTEXITCODE
}

$Process = Start-Process -FilePath $Server -ArgumentList "`"$Ini`"" -WorkingDirectory $PSScriptRoot -PassThru
$Deadline = (Get-Date).AddSeconds(15)
while (-not (Test-Port $Port)) {
    if ($Process.HasExited) { throw "The server stopped with code $($Process.ExitCode), see its log above" }
    if ((Get-Date) -gt $Deadline) { throw "The server isn't listening on $Port after 15 s" }
    Start-Sleep -Milliseconds 100
}

Write-Host "The server runs in its own window (process $($Process.Id)), on 127.0.0.1:$Port."
Write-Host "Try it with: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'Run-Client.ps1')`""
Write-Host "Stop it by typing quit in its window."
