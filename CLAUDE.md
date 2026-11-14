# BakaShrot - start here

A message store with replication: servers take messages per topic/node
from authenticated clients, store them in SQLite, and replicate them
between peers by name. Clients: a C DLL, CLI tools, a Python module. An
**internal tool on trusted machines**.

**Being rewritten in Rust** (since 2026-11-13):

- `revamp.md`: why, what's decided, what's proposed and open, the plan and
  its status. Read it first.
- `Source/`: the new implementation (`Source/README.md`: layout, commands,
  conventions; `Source/docs/`: designs, `protocol.md` first).
- `OldSource/`: the old PureBasic implementation, the reference for the
  behaviour to carry over. It has its own `CLAUDE.md` (build, test, traps),
  `Notes.md` and `Design/`; its paths are relative to `OldSource/`.

## Toolchain

- Rust via rustup, in `%USERPROFILE%\.cargo\bin`, which **isn't on every
  shell's PATH**: prepend it (`export PATH="$HOME/.cargo/bin:$PATH"` in
  bash; `check.ps1` does it itself). The toolchain is pinned
  (`Source/rust-toolchain.toml`, 1.100.0, MSVC; Visual Studio 18 has the
  linker).
- `Source\check.ps1` runs what CI runs; it must pass before a step is done.
- PureBasic 5.73 and 6.40 for `OldSource/`, see `OldSource/CLAUDE.md`.

## Working rules

- **Commit only when the owner asks**, on a branch (`revamp`), not `master`.
- **Follow the plan's order** (`revamp.md`, "Plan"); a step is done when its
  tests pass and its docs are updated, then its status goes in the table.
- **`OldSource/` is the reference:** don't change it beyond keeping it
  building and passing, unless asked.
- **Decisions go in `revamp.md`**: moved to "Decided" only when the owner
  decides, with the date.
- **Use existing crates** rather than reimplementing (MessagePack is `rmp-serde`).
- **Files mix CRLF and LF:** edits must keep each file's line endings
  (`Source/` is LF, the docs at the root and in `OldSource/` mostly CRLF).
- **Bash tool heredocs collapse `\\`:** write edit scripts to files, or use
  the Edit tool.
- **Run exes from a build folder** (`OldSource\Build\`, `Source\target\`):
  the antivirus blocks them in temp folders.
- **Generated keys and certificates never go in git** (`Build/`,
  `target/`). The one exception: `OldSource/Examples/*/` commit theirs on
  purpose (public, example-only, marked so).
