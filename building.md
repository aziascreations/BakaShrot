# BakaShrot - Building

## Compilation
Requires [rustup](https://rustup.rs) (it installs the pinned toolchain, [rust-toolchain.toml](rust-toolchain.toml),
by itself; on Windows, Visual Studio's C++ tools for the linker) and Python 3.11+ for releases.

From the repository's root, on Windows (`powershell -ExecutionPolicy Bypass -File <script>`):

| Script | What it does |
|---|---|
| `build.ps1` | Builds everything, release mode, into `target\release\` (the tool with the `release-tools` profile, copied there); `-HybridCrt` |
| `test.ps1` | What CI runs: formatting, clippy (warnings are errors), the tests, the docs |
| `release.ps1` | A release for this platform, smoke-tested (`release.py`, below); `-SkipTest`, `-HybridCrt` |
| `clean.ps1` | Deletes `target\` (builds and releases) |
| `bench.ps1` | The benchmarks, release mode: pushes, replication, storage (`docs/server.md`, "Measured"); `-Only`, `-Sync full` or `normal` |

Elsewhere, the same with cargo: `cargo build --release` (and `-p bakashrot-tools --profile release-tools`), `cargo test`, `python release.py`, `cargo clean`;
the benchmarks are ignored tests (`cargo test --release -- --ignored`).
Generated keys and certificates never go in git.


## Layout
A Cargo workspace:

```
Cargo.toml              the workspace: shared lints, the release profiles (release-tools: the tool's)
rust-toolchain.toml     the pinned toolchain (1.100.0)
build.ps1, test.ps1, release.ps1, clean.ps1, bench.ps1
release.py              a release for this platform: build, package, smoke test
docs/                   designs across crates: protocol.md, certificates.md, oid.md, config.md,
                        storage.md, server.md, client.md, known-issues.md, lab.md (a test lab, step by step)
crates/
  bakashrot-proto/      packets, frames, names, limits, error codes, shared by everything
  bakashrot-pki/        certificates: issuing, identities, CRLs, the TLS setup
  bakashrot-config/     the server's config (TOML): retention, replication, roles
  bakashrot-storage/    SQLite, schema v9: the writer, reads, attachments, queries
  bakashrot-server/     the server: TLS, identities, requests, the writer thread (and its program)
  bakashrot-client/     the client library, Rust API, blocking
  bakashrot-capi/       the C DLL over bakashrot-client: the BakaShrot_* exports (bakashrot.dll)
  bakashrot-tools/      the CLI tool: bakashrot (push, read, query, list; cert: the certificates)
bindings/
  c/                    bakashrot.h, generated from bakashrot-capi
  purebasic/            the prototypes and error codes
  python/               bakashrot.py over the DLL, check_bakashrot.py, make_wheel.py
.cargo/config.toml      the C runtime linked statically on Windows, SQLite's options
.cargo/hybrid-crt.toml  -HybridCrt: the UCRT from Windows instead (about 180 KB less per program)
docker/                 the server's image: Dockerfile, compose.yml, test.sh
```

Dependencies only point downward: `proto`, `pki`, `config` and `storage` don't open sockets and are tested
on their own; `server` and `client` use them; the DLL and the tool only use `client`.


## Releases
`python release.py` (or `release.ps1`) on Windows or Linux, x64 or ARM64, builds that platform's release into
`target/dist/bakashrot-<version>-<platform>/` and its archive (`.zip`, `.tar.gz`):
the server, `bakashrot` (the certificates too: `bakashrot cert`), the client library with its C header and PureBasic prototypes,
`bakashrot.py` and a wheel with the library in it (`bindings/python/make_wheel.py`), the example configs,
`docs/`, a `README.txt`, the licenses (`THIRD-PARTY.txt`: every crate built in, from `cargo metadata`).

Then it checks it, in the folder's `_test/`: a CA and certificates, the server on a free port,
the tool pushing (an attachment too), reading back, listing and querying, Python through the library
and the wheel installed by pip, the server stopped by SIGTERM (Ctrl+Break on Windows),
which must end cleanly (`_test/` kept if not). `--skip-test` skips it.

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs on a version tag (`v*`) or by hand: `test.ps1`'s checks
on Windows and Linux, then a release on each of Windows x64 and ARM64, Linux x64 and ARM64, each on its own
kind of machine (so its smoke test runs there), its archive kept as the run's artifact. The Linux ones build
in a manylinux 2.28 container, so they run with glibc 2.28 and later.
The version is the workspace's (`Cargo.toml`), and `bindings/python/bakashrot.py`'s `__version__` must be the same.

The server's Docker image: `docker build -f docker/Dockerfile -t bakashrot-server .`, or CI's for amd64
and arm64, checked by `docker/test.sh`, then pushed to `ghcr.io/aziascreations/bakashrot-server` on a tag
(`<version>`, and `latest` unless it's a pre-release: `v0.2.0-test2` doesn't move it). Running it: `docs/server.md`, "In Docker". The package was first pushed by hand, so the
workflow may push to it only with the repository given write access in its settings on GitHub
("Manage Actions access"), once; the package made public there too.

Publishing:
* **The wheel** to Gitea's registry, with twine 6.1+ (for the license metadata) and a token with `write:package`:
  `twine upload --repository-url https://git.nibblepoker.lu/api/packages/aziascreations/pypi -u aziascreations <wheel>`
* **On GitHub** (no Python registry), the archives and the wheels on a release:
  `gh release create v<version> --repo aziascreations/BakaShrot --title <version> <files>`
  (`gh release upload` for one that exists).


## Conventions
* LF line endings (`.gitattributes`; `.ps1` CRLF), rustfmt's defaults.
* Every public item documented (`missing_docs`), no `unsafe` outside the C API crate.
* A crate's root docs say what it does; designs that span crates go in `docs/`, updated with the code.
* Use existing crates rather than reimplementing (MessagePack is `rmp-serde`).
* Protocol changes update `docs/protocol.md`; error codes are never renumbered, packet ids never reused.
