#!/bin/sh
# PreToolUse hook (Write|Edit): block plaintext secrets from landing in files.
# Exit 2 blocks the tool call; stderr goes back to Claude. Best-effort guard,
# not airtight DLP — the Bash tool (redirects, tee) is not matched, and can
# still write secrets; store those with keypass by hand.
# ponytail: greps the raw hook JSON instead of parsing it — token shapes
# survive JSON escaping, and jq would be a dependency.

input=$(cat)

# For Edit, only scan the replacement side — old_string legitimately contains
# secrets when the migrate-secrets skill deletes them from a file.
# ponytail: field-order heuristic (old_string serializes before new_string);
# breaks only if old_string itself contains the literal '"new_string"'.
case $input in
  *'"new_string"'*) scan=${input#*'"new_string"'} ;;
  *) scan=$input ;;
esac
input= # drop the first copy — a Write payload embeds the whole file body

pattern='sk-ant-[A-Za-z0-9_-]{20,}'                       # Anthropic
pattern="$pattern|sk-[A-Za-z0-9_-]{32,}"                  # OpenAI et al.
pattern="$pattern|AKIA[0-9A-Z]{16}"                       # AWS access key
pattern="$pattern|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}"
pattern="$pattern|xox[abprs]-[0-9A-Za-z-]{10,}"           # Slack
pattern="$pattern|AIza[0-9A-Za-z_-]{35}"                  # Google API
pattern="$pattern|eyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}"  # JWT header.payload
pattern="$pattern|-----BEGIN [A-Z ]*PRIVATE KEY-----"

# grep: 0=match, 1=no match, 2=error. Fail closed — a scan that errored must
# not silently let a secret through.
printf '%s' "$scan" | grep -qE "$pattern"
st=$?
case $st in
  1) exit 0 ;;
  0) ;;
  *) echo "block-secrets: scan failed (grep exit $st) — blocking to be safe" >&2; exit 2 ;;
esac

kp="$(cd "$(dirname "$0")/.." && pwd)/scripts/keypass"
cat >&2 <<EOF
Blocked: this write contains what looks like a plaintext API key, JWT, or
private key. Store it in the OS password store instead:

  printf '%s' '<value>' | "$kp" set <service> <KEY_NAME>

then reference it via \$(keypass get <service> <KEY_NAME>) in .envrc or
\${KEY_NAME} expansion in .mcp.json. If this is a deliberate dummy/example
value, tell the user why and let them decide.
EOF
exit 2
