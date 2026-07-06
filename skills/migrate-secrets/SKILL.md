---
name: migrate-secrets
description: Use when the user wants to move API keys, tokens, or JWTs out of .env/config files into the system password store (macOS Keychain, Secret Service/KWallet/gnome-keyring/KeePassXC on Linux and BSD, Windows Credential Manager), or asks to migrate secrets or generate keypass-backed environment files.
---

# Migrate secrets to the OS password store

All storage goes through the bundled CLI, located at
`../../scripts/keypass` relative to this skill's base directory (the path
shown when this skill loads):

    keypass get|set|del <service> <key>
    keypass export <service> <key>...    # sh export lines for many keys, one process

`set` reads the secret from stdin. `get` prints it to stdout. It dispatches to
the native store per platform (Keychain / Secret Service / Credential Manager).

## Steps

1. **Install the CLI on PATH** (once per machine), so every later step and
   the generated files work in and outside Claude Code sessions:

       mkdir -p ~/.local/bin
       ln -sf "<skill-base-dir>/../../scripts/keypass" ~/.local/bin/keypass

   Warn the user if `~/.local/bin` is not on their PATH. Use plain `keypass`
   in all subsequent commands.

2. **Pick the service name.** Default to the project directory name. Confirm
   with the user before proceeding.

3. **Find candidate secrets.** Grep the project for assignments in `.env*`,
   `*.json`, `*.yaml`, `*.yml`, `*.toml`, `*.ini`, and shell scripts whose
   values match secret shapes (`sk-...`, `AKIA...`, `ghp_...`, `xox?-...`,
   `eyJ...eyJ...` JWTs, PEM private keys, or long high-entropy strings
   assigned to names containing KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL).
   Skip `.git`, `node_modules`, lockfiles, and `*.example`/`*.template`
   files.

4. **Confirm the list with the user** before touching anything. Show the
   variable names and source files. Never print a full secret value — show
   the first 8 characters plus total length.

5. **Store each confirmed secret:**

       printf '%s' '<value>' | keypass set <service> <KEY_NAME>

   Verify each one round-trips: `keypass get` output must be the same length
   as what was stored (compare with `wc -c`; do not print the value).

6. **Generate environment files.** Choose by what the project already uses
   (ask if ambiguous):

   - **direnv** (an `.envrc` exists or direnv is installed) — append a single
     batch line listing every migrated key, then remind the user to run
     `direnv allow`:

         eval "$(keypass export <service> OPENAI_API_KEY STRIPE_KEY ...)"

     One process resolves all keys (on Windows this avoids a PowerShell
     start + C# interop compile per key). A missing key prints
     `keypass: missing <service>/<KEY>` on stderr and exits nonzero without
     blocking the other keys.

   - **otherwise** write `secrets.env.sh` at the project root with the same
     single `eval` line, sourced with `. ./secrets.env.sh`.

   - **`.mcp.json`** — replace inline secret values with `${KEY_NAME}`
     env expansion so the file holds no plaintext.

   Make sure the generated files (`.envrc`, `secrets.env.sh`) are listed in
   `.gitignore`; add them if not.

7. **Remove the plaintext from the source files.** Use the Edit tool to
   delete each migrated line and leave a breadcrumb comment, e.g.
   `# OPENAI_API_KEY -> keypass (<service>)`. Do not delete the files
   themselves. (The plugin's secret-write hook only scans the replacement
   side of edits, so removals pass.)

8. **Verify end-to-end:** source the generated file in a fresh shell and
   check each variable is non-empty by length only:

       sh -c '. ./secrets.env.sh; printf %s "$OPENAI_API_KEY" | wc -c'

## Caveats to surface to the user

- **Linux/BSD:** requires a running Secret Service daemon (gnome-keyring,
  KWallet ≥ 5.97, or KeePassXC with Secret Service integration enabled).
  `keypass` exits 69 if no daemon/`secret-tool` is installed. If the daemon
  is running but the keyring is *locked* (headless/SSH, screen locked),
  lookups are capped at a 10s `timeout` and then fail rather than hanging the
  shell — unlock the keyring first for `.envrc` loads to succeed.
- **Transcript/context exposure:** storing a secret means Claude runs
  `printf '%s' '<value>' | keypass set ...`, so the value passes through the
  model context and the session transcript (and shell history). That is a
  broader, longer-lived surface than the source file. On shared or logged
  setups, tell the user and let them store the most sensitive keys by hand.
- **History leakage:** if a secret was ever committed, it lives on in git
  history — offer to check with `git log -S '<first-8-chars>'`. Shell
  history from the migration itself may also hold values; suggest clearing.
- **Claude Code's own key:** the user's Anthropic API key can move too —
  point `apiKeyHelper` in `~/.claude/settings.json` at
  `keypass get <service> ANTHROPIC_API_KEY`.
- **JWTs expire.** Storing one is fine, but refresh remains the app's job;
  re-run `keypass set` to rotate.
