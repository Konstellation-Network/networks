#!/usr/bin/env bash
# devnet-1 only: install the faucet key (created by scripts/devnet-keys.sh) into
# the faucet service's env file, as FAUCET_PRIVATE_KEY, when the faucet is
# deployed (faucet README, "Key handling").
#
# Usage:
#   scripts/devnet-faucet-key.sh --binary <konstellationd> --key-dir <devnet-keys --key-dir> \
#       --to <ssh-host>:<env file on that host>
#   --to <local path> writes a local file instead (no ssh), e.g. for a local run.
#
# Order matters, and is why this is a script rather than a one-line pipe
# (networks PR #5 review):
#   1. The key is exported locally first: the binary asks for a throwaway export
#      password (any 8+ characters, used only in memory) and then the keyring
#      password, on the terminal. ssh is not running yet, so no prompt of its own
#      can collect either password.
#   2. Anything that is not exactly a 64-hex key is refused (a wrong password or
#      an empty export must never be installed as an empty key).
#   3. Only then ssh runs, the key travels on its stdin, and the remote side
#      replaces just the FAUCET_PRIVATE_KEY= line (the rest of the env file, e.g.
#      RPC_URL and CHAIN_ID, is kept), via a 0600 temp file and an atomic mv.
# The key is never an argument, never printed, never in shell history.
set -euo pipefail

die() { echo "devnet-faucet-key: $*" >&2; exit 2; }

binary=""; key_dir=""; to=""
while [ $# -gt 0 ]; do
  case "$1" in
    --binary|--key-dir|--to)
      if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 needs a value"; fi ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  esac
  case "$1" in
    --binary)  binary=$2; shift 2 ;;
    --key-dir) key_dir=$2; shift 2 ;;
    --to)      to=$2; shift 2 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[ -n "$binary" ] || die "--binary <path to konstellationd> is required"
[ -n "$key_dir" ] || die "--key-dir <the directory devnet-keys.sh created> is required"
[ -n "$to" ] || die "--to <ssh-host>:<env file> (or a local path) is required"
[ -x "$binary" ] || die "binary not found or not executable: $binary"
[ -d "$key_dir/keyring-file" ] || die "$key_dir/keyring-file not found: is this the devnet-keys.sh key directory?"
[ -d "$key_dir/validator/config" ] || die "$key_dir/validator/config not found: is this the devnet-keys.sh key directory?"

# 1. Export locally. --home is the key dir's own node home so nothing is written
#    to ~/.konstellationd. Prompts go to the terminal; only stdout is captured.
key=$("$binary" keys unsafe-export-eth-key faucet --keyring-backend file \
        --keyring-dir "$key_dir" --home "$key_dir/validator") || die "export failed (wrong password?); nothing was installed"
key=${key#0x}
# 2. Refuse anything but a 64-hex key.
case "$key" in
  *[!0-9a-fA-F]*|"") unset key; die "export did not return a 64-hex key; nothing was installed" ;;
esac
[ "${#key}" = 64 ] || { unset key; die "export did not return a 64-hex key; nothing was installed"; }

# 3. Install: replace only the FAUCET_PRIVATE_KEY= line, keep the rest.
# shellcheck disable=SC2016 # expanded by the target shell, not here
# One line on purpose: printf %q of a multi-line string yields $'...', which the
# remote /bin/sh (dash on Debian) does not parse.
install='set -eu; umask 077; f=$1; IFS= read -r k; d=$(dirname "$f"); [ -d "$d" ] || { echo "no directory $d" >&2; exit 1; }; t=$(mktemp "$f.XXXXXX"); trap "rm -f \"$t\"" EXIT; if [ -f "$f" ]; then grep -v "^FAUCET_PRIVATE_KEY=" "$f" > "$t" || true; fi; printf "FAUCET_PRIVATE_KEY=%s\n" "$k" >> "$t"; mv "$t" "$f"; trap - EXIT; echo "installed FAUCET_PRIVATE_KEY in $f"'
case "$to" in
  *:*)
    host=${to%%:*}; file=${to#*:}
    if [ -z "$host" ] || [ -z "$file" ]; then die "--to must be <ssh-host>:<env file>"; fi
    # Quoted here, on purpose, so the remote shell gets one argument each.
    # shellcheck disable=SC2029
    printf '%s\n' "$key" | ssh "$host" "sh -c $(printf '%q' "$install") sh $(printf '%q' "$file")"
    ;;
  *)
    printf '%s\n' "$key" | sh -c "$install" sh "$to"
    ;;
esac
unset key
echo "faucet key installed; restart the faucet service so it reads the new env file."
