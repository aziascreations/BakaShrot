# BakaShrot - new sources (Rust)

The new implementation, see `../revamp.md` (why, decisions, the plan and
where it stands).

## Layout

A Cargo workspace. What's marked with a step number is planned, added by
that step of the plan; the rest exists:

```
Source/
  Cargo.toml              the workspace: shared lints, release profile
  rust-toolchain.toml     the pinned toolchain (1.100.0)
  check.ps1               what CI runs: fmt, clippy, tests, docs
  release.py              a release for this platform: build, package, smoke test
  docs/                   designs across crates: protocol.md, certificates.md, oid.md, config.md,
                          storage.md, server.md, client.md
  crates/
    bakashrot-proto/      packets, frames, names, limits, error codes, shared by everything
    bakashrot-pki/        certificates: issuing, identities, CRLs, the TLS setup
    bakashrot-config/     the server's config (TOML): topics, retention, replication, roles
    bakashrot-storage/    SQLite, schema v9: the writer, reads, attachments, queries
    bakashrot-server/     the server: TLS, identities, requests, the writer thread (and its program)
    bakashrot-client/     the client library, Rust API, blocking
    bakashrot-capi/       the C DLL over bakashrot-client: the BakaShrot_* exports (bakashrot.dll)
    bakashrot-tools/      the CLI tools: bakashrot (push, read, query, list), bakashrot-cert
  bindings/
    c/                    bakashrot.h, generated from bakashrot-capi
    purebasic/            the prototypes and error codes, as OldSource/Client/'s
    python/               bakashrot.py over the DLL, check_bakashrot.py, make_wheel.py
  .cargo/config.toml      the C runtime linked statically on Windows
  tests/                  (13) end-to-end suites across processes
```

Dependencies only point downward: `proto`, `pki`, `config` and `storage`
don't open sockets and are tested on their own; `server` and `client` use
them; the DLL and the tools only use `client`.

## Building and checking

- `cargo build`, `cargo test` from `Source/` (rustup picks the pinned
  toolchain).
- `powershell -ExecutionPolicy Bypass -File Source\check.ps1`: everything
  CI checks (`../.github/workflows/source.yml`), warnings are errors.
- Output in `target/` (git-ignored). Generated keys and certificates never
  go in git.

## Releases

`python release.py` (Python 3.11+) on Windows x64 or Linux x86-64 builds
that platform's release into `target/dist/bakashrot-<version>-<platform>/`
and its archive (`.zip`, `.tar.gz`): the server, `bakashrot`,
`bakashrot-cert`, the client library with its C header and PureBasic
prototypes, `bakashrot.py` and a wheel with the library in it
(`bindings/python/make_wheel.py`), the example configs, `docs/`, a
`README.txt`, the licenses (`THIRD-PARTY.txt`: every crate built in, from
`cargo metadata`). Then it checks it, in the folder's `_test/`: a CA and
certificates, the server on a free port, the tool pushing (an attachment
too), reading back, listing and querying, Python through the library and
the wheel installed by pip, the server stopped by SIGTERM (Ctrl+Break on
Windows), which must end cleanly (`_test/` kept if not); `--skip-test`.

CI runs it on a version tag (`v*`) or by hand, keeping the archives: the
Linux one in a manylinux 2.28 container, so it runs with glibc 2.28 and
later. The version is the workspace's (`Cargo.toml`), and
`bindings/python/bakashrot.py`'s `__version__` must be the same.

## Conventions

- LF line endings (`.gitattributes`), rustfmt's defaults.
- Every public item documented (`missing_docs`), no `unsafe` outside the C
  API crate.
- A crate's root docs say what it does; designs that span crates go in
  `docs/`, updated with the code.
- Use existing crates rather than reimplementing (MessagePack is `rmp-serde`).
- Protocol changes update `docs/protocol.md`; error codes are never
  renumbered, packet ids never reused.
