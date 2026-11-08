# Runtime redistributables

DLLs the release needs next to its exes that Windows doesn't always have,
packaged by `Release.ps1`.

| File | Needed by | From | Version |
|---|---|---|---|
| `x64/vcruntime140.dll` | `libsodium.dll` (the official MSVC build) | Visual Studio 2026 (18) Community, `VC\Redist\MSVC\14.51.36231\x64\Microsoft.VC145.CRT\` | 14.51.36247.0 |

SHA-256 of `x64/vcruntime140.dll`:
`D1F4225DF2CD877DBF130D5668A021DCE3F94118455FF5EC952061C30AFC9CE7`

- **Why:** `libsodium.dll` imports `vcruntime140.dll` (the Visual C++
  2015-2026 runtime). Without it, on a Windows without that runtime
  installed, `BakaShrot_Server.exe`, `BakaShrot_Client.dll` and every tool
  fail to load. Next to the exe, it's found before any installed one.
- **Not needed:** the other DLLs of that folder (`msvcp140.dll`,
  `vcruntime140_1.dll`, ...): nothing imports them. The `api-ms-win-crt-*`
  DLLs libsodium also imports are the Universal CRT, part of Windows 10 and
  later, so the release needs Windows 10+.
- **Allowed:** files from Visual Studio's `VC\Redist` folder are the ones its
  license lets you redistribute with an app.
- **Updating:** copy the newer one from that folder, update this table and
  the hash. To check what a binary imports:
  `grep -a -o -i -E "(vcruntime[0-9_]*|msvcp[0-9_]*|api-ms-win-crt-[a-z0-9-]+)\.dll" <file>`
- x86 isn't built, so there's no `x86/`.
