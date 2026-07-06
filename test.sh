#!/bin/sh
# Self-check for keypass. Plain POSIX sh, no keyring, no framework: a fake
# secret-tool on PATH drives scripts/keypass, and fabricated hook JSON drives
# block-secrets.sh. Run: sh test.sh
#
# NOT covered: scripts/keypass.ps1 (advapi32 P/Invoke needs a real Windows
# box — mocking it would test the mock, not the code) and the live macOS
# security(1) / Linux secret-tool round-trips.
set -u
here=$(cd "$(dirname "$0")" && pwd)
fails=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# --- fake Secret Service backend on PATH ---------------------------------
shim=$(mktemp -d)
trap 'rm -rf "$shim"' EXIT
cat >"$shim/secret-tool" <<'EOF'
#!/bin/sh
# lookup service <svc> key <KEY>  -> value on stdout, or exit 1 if unknown
[ "$1" = lookup ] || exit 0
case $5 in
  PLAIN)  printf 'plainval' ;;
  QUOTED) printf "a'b'c" ;;    # embedded single quotes — the escaping test
  *) exit 1 ;;                 # unknown key -> "missing"
esac
EOF
chmod +x "$shim/secret-tool"
# force the Secret Service branch regardless of the host OS
kp() { OSTYPE=linux-gnu PATH="$shim:$PATH" sh "$here/scripts/keypass" "$@"; }
rc() { "$@" >/dev/null 2>&1; echo $?; }

# --- keypass: arg parsing / arity / key validation -----------------------
check "too few args -> 64"        64 "$(rc kp get svc)"
check "unknown verb -> 64"        64 "$(rc kp bogus svc KEY)"
check "get with extra key -> 64"  64 "$(rc kp get svc K1 K2)"
check "injection key name -> 64"  64 "$(rc kp export svc 'X$(touch pwned)')"
check "key with dash -> 64"       64 "$(rc kp get svc BAD-NAME)"
check "leading digit key -> 64"   64 "$(rc kp get svc 1KEY)"
[ -e "$here/pwned" ] && { echo "FAIL injection actually ran"; fails=$((fails + 1)); rm -f "$here/pwned"; }

# --- keypass: get normalization (no trailing newline) --------------------
check "get value"        "plainval" "$(kp get svc PLAIN 2>/dev/null)"
check "get byte count"   "8"        "$(kp get svc PLAIN 2>/dev/null | wc -c | tr -d ' ')"
check "get missing -> 1" 1          "$(rc kp get svc NOPE)"

# --- keypass: export quoting + missing-key semantics ---------------------
out=$(kp export svc PLAIN QUOTED MISSING 2>/dev/null); erc=$?
check "export rc on miss -> 1" 1 "$erc"
# the emitted lines must eval back to the exact stored values, quotes intact
PLAIN='' QUOTED=''; eval "$out"
check "export PLAIN survives eval"  "plainval" "$PLAIN"
check "export QUOTED survives eval" "a'b'c"    "$QUOTED"

# --- keypass: dispatch forwards correct argv (fake security, OSTYPE) ------
cat >"$shim/security" <<'EOF'
#!/bin/sh
printf '%s\n' "$*"
EOF
chmod +x "$shim/security"
argv=$(OSTYPE=darwin PATH="$shim:$PATH" sh "$here/scripts/keypass" get svc MYKEY 2>/dev/null)
check "darwin get forwards flags" "find-generic-password -s svc -a MYKEY -w" "$argv"

# --- hook: block/allow matrix (min-length tokens matter) -----------------
hook() { printf '%s' "$1" | sh "$here/hooks/block-secrets.sh" >/dev/null 2>&1; echo $?; }
w() { printf '{"tool_name":"Write","tool_input":{"content":"%s"}}' "$1"; }
check "block anthropic" 2 "$(hook "$(w 'K=sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA')")"
check "block aws"       2 "$(hook "$(w 'K=AKIAIOSFODNN7EXAMPLE')")"
check "block github"    2 "$(hook "$(w 'K=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789')")"
check "block slack"     2 "$(hook "$(w 'K=xoxb-0123456789-abcdefghij')")"
check "block google"    2 "$(hook "$(w 'K=AIzaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')")"
check "block jwt"       2 "$(hook "$(w 'K=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0')")"
check "block pem"       2 "$(hook "$(w '-----BEGIN RSA PRIVATE KEY-----')")"
check "allow clean"     0 "$(hook "$(w 'just some ordinary text')")"
check "allow short sk"  0 "$(hook "$(w 'K=sk-tooshort')")"
# migrate-skill invariant: secret only in old_string (a removal) must pass
rem='{"tool_input":{"old_string":"K=sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA","new_string":"# K -> keypass"}}'
check "edit removal passes" 0 "$(hook "$rem")"
add='{"tool_input":{"old_string":"K=","new_string":"K=sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA"}}'
check "edit addition blocked" 2 "$(hook "$add")"

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) FAILED"; exit 1; fi
