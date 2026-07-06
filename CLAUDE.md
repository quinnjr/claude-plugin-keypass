# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code plugin that moves API keys and JWTs out of project files into
the OS-native password store, and keeps them out afterward. Three cooperating
parts:

- **`scripts/keypass`** — a POSIX sh CLI (`get`/`set`/`del`/`export`) that
  dispatches to the native backend per platform.
- **`hooks/block-secrets.sh`** — a `PreToolUse` hook (on `Write|Edit`, wired
  in `hooks/hooks.json`) that blocks plaintext secrets from being written to
  files.
- **`skills/migrate-secrets/SKILL.md`** — instructions a Claude instance
  follows to find secrets, store them via the CLI, generate env files, and
  strip the plaintext.

## Testing

```sh
sh test.sh          # full self-check, ~24 assertions, no keyring needed
```

`test.sh` uses a `mktemp -d` PATH shim for `secret-tool`/`security`, so it
runs anywhere including CI without a real credential store. There is no build
step, no linter config, and no package manager — always `sh -n <script>` after
editing a shell script, then run `test.sh`.

**`scripts/keypass.ps1` (Windows Credential Manager backend) is not covered by
`test.sh`** — its advapi32 P/Invoke needs a real Windows box, and mocking it
would test the mock. Any change to it is unverifiable here; say so, and smoke-
test `keypass set`/`get`/`export` on Windows.

## Hard constraints

- **Zero external dependencies.** POSIX sh + OS-native tools only — no `jq`,
  no `python`, no `awk` if avoidable. `keypass.ps1` may use only built-in
  .NET via `Add-Type`. Reaching for a dependency is the wrong instinct here;
  the JSON in `block-secrets.sh` is deliberately grepped, not parsed.
- **`ponytail:` comments** mark deliberate shortcuts with a named ceiling.
  Don't "fix" the thing one annotates unless the stated ceiling is wrong.

## Architecture invariants (the non-obvious parts)

**Three backends, one contract.** `scripts/keypass` branches on
`${OSTYPE:-$(uname -s)}`: `security(1)` on macOS, `keypass.ps1` (via
`powershell.exe`) on MSYS/Cygwin, `secret-tool` (Secret Service — gnome-
keyring/KWallet/KeePassXC, also the BSDs) everywhere else. The three must
behave identically for a given verb: `get` emits the secret with **no trailing
newline**, `del` is **idempotent** (absent key = exit 0), `set` reads the
**whole** stdin payload (multi-line safe). When you touch one backend, check
the other two for drift — this is the most common way a change breaks.

**The `export`/`eval` contract is load-bearing and duplicated across
languages.** `keypass export` prints `export KEY='value'` lines that the
consumer `eval`s (generated `.envrc` does `eval "$(keypass export …)"`). Two
things follow:
  1. Key names are validated against `[A-Za-z_][A-Za-z0-9_]*` on **every**
     verb, in **both** `scripts/keypass` and `keypass.ps1`. This is a security
     boundary, not a nicety — an unvalidated key name reaches an `eval` sink
     (command injection). Never weaken it.
  2. The single-quote escaping (`'\''`) and the exact line shape are
     implemented once in sh and once in PowerShell. They are marked as a
     matched pair in comments — change both together or eval'd environments
     diverge per-OS.

**The hook scans only the replacement side of an Edit.** `block-secrets.sh`
strips everything up to `"new_string"` before matching, so *removing* a secret
from a file passes (the migrate skill relies on this). The matcher is
`Write|Edit` only — `MultiEdit` was intentionally dropped because the single-
`new_string` strip can't handle its multi-edit payload. The hook fails
**closed**: a `grep` error blocks rather than allows.

**Secret Service lookups are capped with `timeout 10`.** A locked keyring
otherwise blocks forever on an unlock prompt and hangs every shell that
sources a generated `.envrc`. Keep the timeout; exit 124 is surfaced as
"keyring unavailable" distinct from a genuinely missing key.

## Editing this repo with the plugin enabled

`block-secrets.sh` will block a `Write`/`Edit` whose new content matches a
secret pattern — including realistic-looking test fixtures. `test.sh` uses
example tokens shaped to trip the patterns on purpose; if you need to add such
a fixture, that's the expected friction, not a bug.
