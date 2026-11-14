# X.509 certificates (Commons/Cryptography/Der.pbi, X509.pbi): Build\X509Test.exe's
# own checks, then both ways with OpenSSL, if it's on the PATH (Git for Windows
# has one): OpenSSL's Ed25519 CA, leaf (DER, with BakaShrot's custom extensions)
# and an RSA certificate are read and checked by X509Test.exe; its CA, leaves,
# chain, private key and a leaf it issued with OpenSSL's CA are checked by OpenSSL.
# Needs Build\X509Test.exe (compile Tests\X509Test.pb into it). No server, no port.
# Usage: powershell -ExecutionPolicy Bypass -File Tests\X509-Test.ps1
param([string]$Build = (Join-Path $PSScriptRoot "..\Build"))
$ErrorActionPreference = "Stop"
$Build = (Resolve-Path $Build).Path
$Dir = Join-Path $Build "_x509test"
Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory $Dir | Out-Null
$Fails = 0

# BakaShrot's extensions arc (#BakaShrot_Oid_Extensions), the test's numbers.
$Arc = "2.25.232025699926348910519219903487382490981.1"
# X509Test.pb's Now, its certificates are valid then.
$TestNow = 1800000000

function Check([string]$What, [bool]$Ok, [string]$Detail) {
    if (-not $Ok) { $script:Fails++ }
    if ($Detail.Length -gt 300) { $Detail = $Detail.Substring(0, 300) + "... (" + $Detail.Length + " chars)" }
    "{0} {1}`n      -> {2}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $What, $Detail
}

$OpenSsl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
if (-not $OpenSsl -and $env:ProgramFiles) {
    # Git for Windows' own, when its folders aren't on the PATH.
    $OpenSsl = @("ucrt64", "mingw64", "usr") | ForEach-Object { Join-Path $env:ProgramFiles "Git\$_\bin\openssl.exe" } | Where-Object { Test-Path $_ } | Select-Object -First 1
}
# Runs OpenSSL in the test's folder, its output joined (Out).
function Ssl([string[]]$A) {
    $ErrorActionPreference = "Continue"
    Push-Location $Dir
    try { $O = @(& $OpenSsl @A 2>&1 | ForEach-Object { "$_" }) } finally { Pop-Location }
    @{ Code = $LASTEXITCODE; Out = ($O -join " | ") }
}

if ($OpenSsl) {
    "OpenSSL: $OpenSsl ($((Ssl @("version")).Out))"
    $R = Ssl @("genpkey", "-algorithm", "ed25519", "-out", "openssl-ca-key.pem")
    Check "OpenSSL: CA key" ($R.Code -eq 0) $R.Out
    $R = Ssl @("req", "-x509", "-new", "-key", "openssl-ca-key.pem", "-subj", "/CN=OpenSSL Test CA/O=BakaShrot", "-days", "3650",
               "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-out", "openssl-ca.pem")
    Check "OpenSSL: CA" ($R.Code -eq 0) $R.Out
    $R = Ssl @("genpkey", "-algorithm", "ed25519", "-out", "openssl-leaf-key.pem")
    $R = Ssl @("req", "-new", "-key", "openssl-leaf-key.pem", "-subj", "/CN=kitchen", "-out", "openssl-leaf.csr")
    Check "OpenSSL: leaf request" ($R.Code -eq 0) $R.Out
    Set-Content (Join-Path $Dir "leaf.ext") -Encoding Ascii -Value @"
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
$Arc.9000 = ASN1:UTF8String:from-openssl
$Arc.9001 = ASN1:INTEGER:42
"@
    $R = Ssl @("x509", "-req", "-in", "openssl-leaf.csr", "-CA", "openssl-ca.pem", "-CAkey", "openssl-ca-key.pem", "-days", "365",
               "-extfile", "leaf.ext", "-outform", "DER", "-out", "openssl-leaf.der")
    Check "OpenSSL: leaf, with BakaShrot's extensions, as DER" ($R.Code -eq 0) $R.Out
    $R = Ssl @("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "openssl-rsa-key.pem", "-subj", "/CN=RSA", "-days", "1", "-out", "openssl-rsa.pem")
    Check "OpenSSL: an RSA certificate" ($R.Code -eq 0) $R.Out
} else {
    "SKIP OpenSSL isn't on the PATH: only X509Test.exe's own checks"
}

# X509Test.exe, from Build\ (the antivirus blocks exes elsewhere).
Push-Location $Build
try { $Out = @(& (Join-Path $Build "X509Test.exe") "$Dir\" 2>&1 | ForEach-Object { "$_" }); $Code = $LASTEXITCODE } finally { Pop-Location }
$Out
$Passed = @($Out | Where-Object { $_ -match "^PASS " }).Count
Check "X509Test.exe" ($Code -eq 0) "exit $Code, $Passed checks passed"

if ($OpenSsl) {
    $R = Ssl @("verify", "-attime", "$TestNow", "-CAfile", "bakashrot-ca.pem", "bakashrot-leaf.pem")
    Check "OpenSSL verifies BakaShrot's leaf with its CA" (($R.Code -eq 0) -and ($R.Out -match "bakashrot-leaf.pem: OK")) $R.Out
    $R = Ssl @("verify", "-attime", "$TestNow", "-CAfile", "bakashrot-ca.pem", "-untrusted", "bakashrot-intermediate.pem", "bakashrot-deep.pem")
    Check "OpenSSL verifies BakaShrot's chain (leaf, intermediate, CA)" (($R.Code -eq 0) -and ($R.Out -match "bakashrot-deep.pem: OK")) $R.Out
    $R = Ssl @("verify", "-attime", "$TestNow", "-CAfile", "bakashrot-ca.pem", "bakashrot-deep.pem")
    Check "OpenSSL refuses the chain without its intermediate" ($R.Code -ne 0) $R.Out
    $R = Ssl @("verify", "-attime", "$($TestNow + 2 * 365 * 86400)", "-CAfile", "bakashrot-ca.pem", "bakashrot-leaf.pem")
    Check "OpenSSL refuses BakaShrot's leaf once expired" (($R.Code -ne 0) -and ($R.Out -match "expired")) $R.Out
    $R = Ssl @("verify", "-CAfile", "openssl-ca.pem", "bakashrot-by-openssl-ca.pem")
    Check "OpenSSL verifies a leaf BakaShrot issued with OpenSSL's CA" (($R.Code -eq 0) -and ($R.Out -match ": OK")) $R.Out

    $R = Ssl @("x509", "-in", "bakashrot-ca.pem", "-noout", "-text")
    Check "OpenSSL reads BakaShrot's CA: Ed25519, CA, path length, key usage" (($R.Out -match "ED25519") -and ($R.Out -match "CA:TRUE, pathlen:1") -and ($R.Out -match "Certificate Sign, CRL Sign") -and ($R.Out -match "Subject: CN=BakaShrot Test CA, O=BakaShrot, C=LU")) $R.Out
    $R = Ssl @("x509", "-in", "bakashrot-leaf.pem", "-noout", "-text")
    Check "OpenSSL reads BakaShrot's leaf: its custom extensions, key ids" (($R.Out -match [regex]::Escape("$Arc.9000")) -and ($R.Out -match [regex]::Escape("$Arc.9002")) -and ($R.Out -match "Subject Key Identifier") -and ($R.Out -match "Authority Key Identifier") -and ($R.Out -match "Serial Number: 4328719365")) $R.Out
    $R = Ssl @("x509", "-in", "bakashrot-leaf.pem", "-noout", "-fingerprint", "-sha256")
    $Ours = (Get-Content (Join-Path $Dir "bakashrot-leaf.sha256") -Raw).Trim()
    $Theirs = (($R.Out -replace "^.*=", "") -replace ":", "").ToLower()
    Check "Fingerprints match OpenSSL's" ($Ours -eq $Theirs) "$Ours / $Theirs"
    $Key = Ssl @("pkey", "-in", "bakashrot-leaf-key.pem", "-pubout")
    $Cert = Ssl @("x509", "-in", "bakashrot-leaf.pem", "-noout", "-pubkey")
    Check "OpenSSL reads BakaShrot's private key, the leaf's" (($Key.Code -eq 0) -and ($Key.Out -eq $Cert.Out) -and ($Key.Out -match "BEGIN PUBLIC KEY")) "$($Key.Out) / $($Cert.Out)"
}

""
if ($Fails) { "$Fails check(s) failed"; exit 1 }
"All checks passed"
exit 0
