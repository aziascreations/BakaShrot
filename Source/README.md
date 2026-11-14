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
    python/               bakashrot.py over the DLL, check_bakashrot.py (its wheel: 12)
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

## Conventions

- LF line endings (`.gitattributes`), rustfmt's defaults.
- Every public item documented (`missing_docs`), no `unsafe` outside the C
  API crate.
- A crate's root docs say what it does; designs that span crates go in
  `docs/`, updated with the code.
- Use existing crates rather than reimplementing (MessagePack is `rmp-serde`).
- Protocol changes update `docs/protocol.md`; error codes are never
  renumbered, packet ids never reused.
