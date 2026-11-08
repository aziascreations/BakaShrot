# End-to-end test of the Python interactor (Interactors/Python/bakashrot.py):
# starts a server with an empty database and runs
# Interactors/Python/check_bakashrot.py against it, through Build\'s DLL,
# then Tests/wire_check.py: what goes over the wire is encrypted.
# Needs Build\ (Build.ps1), Build\Bench\BenchServer.exe (Bench-Replication.ps1,
# or compile Tests\Bench\BenchServer.pb into it) and a 64-bit Python 3.8+.
# Uses ports 12406 and 12407.
# Usage: powershell -ExecutionPolicy Bypass -File Tests\Python-Test.ps1 [-Python <python.exe>]
param(
    [string]$Build = (Join-Path $PSScriptRoot "..\Build"),
    [string]$Python = "python"
)
$ErrorActionPreference = "Stop"
$Build = (Resolve-Path $Build).Path
$Dir = Join-Path $Build "_pythontest"
Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory $Dir | Out-Null
$Server = Join-Path $Build "Bench\BenchServer.exe"
$Port = 12406
$ProxyPort = 12407

function New-KeyPair {
    $L = & (Join-Path $Build "KeyGen.exe")
    @{ Priv = $L[0] -replace "^PrivateKey = ", ""; Pub = $L[1] -replace "^PublicKey = ", "" }
}
function Test-Port($P) {
    $C = New-Object System.Net.Sockets.TcpClient
    try { $A = $C.BeginConnect("127.0.0.1", $P, $null, $null); $A.AsyncWaitHandle.WaitOne(200) -and $C.Connected } catch { $false } finally { $C.Close() }
}

$S = New-KeyPair; $K = New-KeyPair; $L = New-KeyPair

Set-Content (Join-Path $Dir "server.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($S.Priv)
Topic = logs
Node = server

[BakaShrot.Topics]
logs = 1
secret = 2

[BakaShrot.Nodes]
server = 1
kitchen = 5
lounge = 6

[BakaShrot.Server]
Host = 127.0.0.1
Port = $Port
DatabasePath = $(Join-Path $Dir "server.sqlite")

[BakaShrot.Client.kitchen]
PublicKeys = $($K.Pub)
Identities = logs:kitchen
PushTopics = logs;secret
ReadTopics = *
AllowQuery = 1

[BakaShrot.Client.lounge]
PublicKeys = $($L.Pub)
Identities = logs:lounge
ReadTopics = logs
"@

function Client-Ini($Name, $Keys) {
    $P = Join-Path $Dir "$Name.ini"
    Set-Content $P -Encoding Ascii -Value "[BakaShrot]`r`nPrivateKey = $($Keys.Priv)`r`nPublicKey = $($Keys.Pub)`r`nTopic = logs`r`nNode = $Name`r`nServerHost = 127.0.0.1`r`nServerPort = $Port`r`nServerPublicKey = $($S.Pub)"
    $P
}
$Kitchen = Client-Ini "kitchen" $K
$Lounge  = Client-Ini "lounge" $L

if (Test-Port $Port) { throw "Port $Port is already in use" }
$Stop = Join-Path $Dir "server.stop"
$P = Start-Process -FilePath $Server -ArgumentList "`"$(Join-Path $Dir "server.ini")`"", "`"$Stop`"" -WorkingDirectory $Dir `
    -RedirectStandardOutput (Join-Path $Dir "server.log") -WindowStyle Hidden -PassThru
$null = $P.Handle
$Code = 1
try {
    $D = (Get-Date).AddSeconds(15)
    while (-not (Test-Port $Port)) {
        if ($P.HasExited) { throw "The server exited: $(Get-Content (Join-Path $Dir "server.log") -Raw)" }
        if ((Get-Date) -gt $D) { throw "The server isn't listening" }
        Start-Sleep -Milliseconds 100
    }

    $env:PYTHONIOENCODING = "utf-8"
    & $Python (Join-Path $PSScriptRoot "..\Interactors\Python\check_bakashrot.py") (Join-Path $Build "BakaShrot_Client.dll") $Kitchen $Lounge
    $Code = $LASTEXITCODE

    $Bad = @(Get-Content (Join-Path $Dir "server.log") | Where-Object { $_ -match "invalid|unexpected|Failed|decrypt|sealed" })
    if ($Bad.Count) { "FAIL Server log: $($Bad -join ' / ')"; $Code = 1 } else { "PASS Server log: no invalid or unexpected packets" }

    # The wire: encrypted, tampering and a wrong server key refused. Another
    # key pair's public key plays the wrong server's.
    ""
    & $Python -B (Join-Path $PSScriptRoot "wire_check.py") (Join-Path $Build "BakaShrot_Client.dll") $Kitchen $ProxyPort $L.Pub
    if ($LASTEXITCODE) { $Code = 1 }
    Start-Sleep -Milliseconds 300
    $Log = Get-Content (Join-Path $Dir "server.log")
    $Checks = [ordered]@{
        "Server log: the tampered packet didn't decrypt" = "sent a packet that doesn't decrypt"
        "Server log: the hello for another server wasn't opened" = "hello that isn't sealed for this server"
    }
    foreach ($Name in $Checks.Keys) {
        if (@($Log | Where-Object { $_ -match [regex]::Escape($Checks[$Name]) }).Count) { "PASS $Name" } else { "FAIL $Name"; $Code = 1 }
    }
}
finally {
    if (-not $P.HasExited) {
        Set-Content $Stop "x"
        if (-not $P.WaitForExit(15000)) { Stop-Process -Id $P.Id -Force }
    }
}
exit $Code
