# keypass

A [Claude Code](https://claude.ai/code) plugin that moves API keys and JWTs
out of your project files and into the operating system's password store —
then keeps them out.

Secrets sitting in `.env` files, `.mcp.json`, and scattered config are the
easiest thing in the world to `git commit` by accident, paste into a chat, or
leak through a backup. Your OS already ships an encrypted, access-controlled
place for them: the macOS Keychain, the Linux/BSD Secret Service (gnome-
keyring, KWallet, KeePassXC), or the Windows Credential Manager. `keypass`
migrates your secrets there and wires your project to read them back at
runtime, so the plaintext lives in exactly one protected place.

**Zero dependencies.** Pure POSIX `sh` plus whatever secret store your OS
already runs. No `jq`, no Python, no runtime to install.

## How it works

Three parts:

| Part | What it does |
|------|--------------|
| **`keypass` CLI** | `get` / `set` / `del` / `export` secrets, dispatching to your platform's native store. |
| **Secret-blocking hook** | A `PreToolUse` hook that stops Claude from writing a plaintext key or JWT into a file. |
| **`migrate-secrets` skill** | Walks Claude through finding your existing secrets, storing them, generating env files, and stripping the plaintext. |

The CLI picks a backend from your platform automatically:

| Platform | Store | Underlying tool |
|----------|-------|-----------------|
| macOS | Keychain | `security(1)` (built in) |
| Linux, FreeBSD, OpenBSD, NetBSD, DragonFly | Secret Service over D-Bus | `secret-tool` — one interface for gnome-keyring, KWallet ≥ 5.97, or KeePassXC |
| Windows (Git Bash / MSYS / Cygwin) | Credential Manager | bundled PowerShell backend (advapi32, no modules) |

## Requirements

- **macOS** — nothing; `security` is built in.
- **Linux / BSD** — `secret-tool` (from `libsecret`) and a running Secret
  Service daemon: gnome-keyring, KWallet ≥ 5.97, or KeePassXC with Secret
  Service integration enabled. On Arch: `sudo pacman -S libsecret`.
- **Windows** — nothing extra; the bundled backend talks to Credential
  Manager directly.

The keyring must be **unlocked** for lookups to succeed. On headless/SSH or
locked-screen sessions, lookups time out after 10s and fail loudly rather than
hanging your shell — unlock the keyring first.

## Install

Add the plugin to Claude Code (adjust the path/source to how you distribute
plugins in your setup), then optionally put the CLI on your `PATH` so the
generated env files work outside Claude Code too:

```sh
ln -sf /path/to/claude-plugin-keypass/scripts/keypass ~/.local/bin/keypass
```

## Usage

### Migrate an existing project

In a project that has secrets in `.env` / config files, ask Claude:

> migrate my secrets to the system password store

The `migrate-secrets` skill takes over: it finds secret-shaped values,
confirms the list with you (never printing full values), stores each one,
generates the env wiring, and removes the plaintext from your files — leaving
a breadcrumb comment where each value used to be.

### Use the CLI directly

```sh
# store a secret (read from stdin — never passed as an argument)
printf '%s' 'sk-...' | keypass set myproject OPENAI_API_KEY

# read it back (no trailing newline)
keypass get myproject OPENAI_API_KEY

# load many secrets into your shell in one shot
eval "$(keypass export myproject OPENAI_API_KEY STRIPE_KEY DATABASE_URL)"

# remove one (idempotent — deleting a missing key succeeds)
keypass del myproject OPENAI_API_KEY
```

The first argument is a **service** namespace (use the project name); the rest
are key names. `export` resolves every key in a single process — one backend
round-trip — which is what makes it cheap to call from an `.envrc`.

### Wire it into your project

Point your tooling at the store instead of at plaintext:

```sh
# .envrc (direnv) — one line, all keys, re-read on every shell load
eval "$(keypass export myproject OPENAI_API_KEY STRIPE_KEY)"
```

```jsonc
// .mcp.json — reference the env populated above, no secret in the file
{ "env": { "OPENAI_API_KEY": "${OPENAI_API_KEY}" } }
```

For Claude Code's own Anthropic key, set `apiKeyHelper` in
`~/.claude/settings.json` to `keypass get myproject ANTHROPIC_API_KEY`.

### The safety net

While the plugin is enabled, a `PreToolUse` hook watches every `Write` and
`Edit`. If Claude tries to write something shaped like an API key, JWT, or PEM
private key into a file, the write is **blocked** with a note to store it in
`keypass` instead. Removing a secret from a file is always allowed, so the
migration itself isn't caught in its own net.

This is a helpful guardrail, not airtight DLP: secrets written through the
Bash tool (`echo … > .env`) aren't intercepted. Store those with `keypass` by
hand.

## Key names are validated

Key names must match `[A-Za-z_][A-Za-z0-9_]*`. This isn't cosmetic:
`keypass export` emits shell `export` lines that you `eval`, so an unchecked
key name would be a command-injection vector. Names are validated on every
verb and on every backend.

## Testing

```sh
sh test.sh
```

Runs the full self-check with a fake backend on `PATH`, so it needs no real
keyring and works in CI. The Windows Credential Manager backend
(`scripts/keypass.ps1`) requires a real Windows machine to exercise and is
not covered by the suite.

## Caveats

- **JWTs expire.** Storing one is fine; refreshing it stays your app's job.
  Re-run `keypass set` to rotate.
- **Git history.** If a secret was ever committed, migrating the working copy
  doesn't scrub history — check with `git log -S '<first-8-chars>'` and
  rewrite if needed.
- **Portability of the value.** Multi-line secrets (PEM keys) round-trip
  correctly on all backends; `get` never appends a trailing newline.

## License

MIT — see [LICENSE](LICENSE).
