# BakaShrot - start here

A message store with replication: servers take messages per topic/node
from authenticated clients, store them in SQLite, and replicate them
between peers by name. Clients: a C DLL, CLI tools, a Python module. An
**internal tool on trusted machines**.

**Rewritten in Rust** (since 2026-11-13):

- `revamp.md`: why, what's decided, what's proposed and open, the plan and
  its status. Read it first.
- The implementation is the Cargo workspace at the root (`readme.md`:
  layout, scripts, conventions; `docs/`: designs, `protocol.md` first,
  `known-issues.md` for what's left).
- The old PureBasic implementation was removed on 2026-11-15: it's in git
  history, `OldSource/` up to commit `68966a8`. Paths starting with
  `OldSource/` in the code and docs point there.

## Toolchain

- Rust via rustup, in `%USERPROFILE%\.cargo\bin`, which **isn't on every
  shell's PATH**: prepend it (`export PATH="$HOME/.cargo/bin:$PATH"` in
  bash; the `.ps1` scripts and `release.py` do it themselves). The toolchain is pinned
  (`rust-toolchain.toml`, 1.100.0, MSVC; Visual Studio 18 has the
  linker).
- `test.ps1` runs what CI runs; it must pass before a step is done
  (`build.ps1`, `release.ps1`, `clean.ps1`, `bench.ps1` beside it, see `readme.md`).
  Run them by absolute path (`-File <repo>\test.ps1`): a relative one
  fails when the shell's folder differs.

## Working rules

- **Commit only when the owner asks**, on a branch (`revamp`), not `master`.
- **Follow the plan's order** (`revamp.md`, "Plan"); a step is done when its
  tests pass and its docs are updated, then its status goes in the table.
- **Decisions go in `revamp.md`**: moved to "Decided" only when the owner
  decides, with the date.
- **Use existing crates** rather than reimplementing (MessagePack is `rmp-serde`).
- **Line endings:** LF everywhere, `.ps1` CRLF (`.gitattributes`); edits
  must keep them.
- **Bash tool heredocs collapse `\\`:** write edit scripts to files, or use
  the Edit tool.
- **Run exes from a build folder** (`target\`):
  the antivirus blocks them in temp folders.
- **Generated keys and certificates never go in git** (`target/`).
