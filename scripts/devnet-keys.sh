#!/usr/bin/env bash
# devnet-1 only: create every devnet-1 key once, on the founder's PC, and cut
# devnet-1's genesis from them (ENGINEERING.md §15 phase 4b, §18; STATUS P29).
#
# One run does the whole ceremony, because devnet-1 has one foundation-run
# validator and one key holder:
#   1. keys, in a password-protected `file` keyring in a new directory outside
#      any git work tree (never the `test` backend);
#   2. devnet-1/allocations.json: allocations.example.json with those addresses;
#   3. scripts/gen-genesis.sh devnet-1 --pre-gentx, the validator's gentx against
#      it, then the final gen-genesis.sh --gentxs ... --circuit-admin ...,
#      run twice to prove the output is byte-identical;
#   4. scripts/verify.sh devnet-1 with the binary on PATH.
# testnet-1 and konstellation-1 do NOT use this script: their validators and
# circuit admin are different people/multisigs (D7, D16, STATUS P32).
#
# Usage (run once, after the release tag exists; see devnet-1/README.md):
#   GENESIS_TIME=<rfc3339, e.g. 2026-10-15T12:00:00Z> scripts/devnet-keys.sh \
#       --binary <path/to/konstellationd built from the release tag> \
#       --key-dir <new directory outside any git repo, e.g. ~/konstellation-keys/devnet-1>
#   Options:
#     --moniker <name>              validator moniker, 1-70 characters (default devnet-1-validator)
#     --self-delegation <KASH>      gentx self-delegation, whole KASH (default: the
#                                   validator bootstrap row minus 1 000 KASH, which
#                                   stays liquid so the operator can pay fees to
#                                   withdraw rewards or edit the validator)
#     --min-self-delegation <esp>   default 1 (the SDK default, in esp)
#     --commission-rate <dec>       default 0.05 (x/staking min_commission_rate, D10)
#     --commission-max-rate <dec>   default 0.20
#     --commission-max-change-rate <dec>  default 0.01
#     --p2p-ip <ip>                 IP in the gentx memo (<node-id>@<ip>:26656),
#                                   which is published in genesis.json. Default
#                                   127.0.0.1 so the PC's LAN address and the
#                                   validator's real address stay out of it;
#                                   peering comes from persistent_peers.txt.
#
# The keyring password is asked twice on the terminal and fed to each
# konstellationd call on stdin; it is never an argument or an env var.
# Nothing secret is printed: mnemonics are not generated for display
# (`keys add --no-backup`), the faucet's EVM key is not exported (that is
# scripts/devnet-faucet-key.sh, at faucet deploy time). What to back up, what
# goes to the validator server and the next steps are printed at the end.
# Every binary call gets an explicit --home, so nothing is written to
# ~/.konstellationd on this PC.
set -euo pipefail

net=devnet-1
repo=$(cd "$(dirname "$0")/.." && pwd -P)

die() { echo "devnet-keys: $*" >&2; exit 2; }

binary=""; key_dir=""; moniker="devnet-1-validator"; self_delegation=""
min_self_delegation=1; commission_rate=0.05; commission_max_rate=0.20
commission_max_change_rate=0.01; p2p_ip=127.0.0.1
while [ $# -gt 0 ]; do
  case "$1" in
    --binary|--key-dir|--moniker|--self-delegation|--min-self-delegation|--commission-rate|--commission-max-rate|--commission-max-change-rate|--p2p-ip)
      if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 needs a value"; fi ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  esac
  case "$1" in
    --binary)                     binary=$2; shift 2 ;;
    --key-dir)                    key_dir=$2; shift 2 ;;
    --moniker)                    moniker=$2; shift 2 ;;
    --self-delegation)            self_delegation=$2; shift 2 ;;
    --min-self-delegation)        min_self_delegation=$2; shift 2 ;;
    --commission-rate)            commission_rate=$2; shift 2 ;;
    --commission-max-rate)        commission_max_rate=$2; shift 2 ;;
    --commission-max-change-rate) commission_max_change_rate=$2; shift 2 ;;
    --p2p-ip)                     p2p_ip=$2; shift 2 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# --- preflight: everything that can fail is checked before any key exists ----
[ -n "$binary" ] || die "--binary <path to konstellationd> is required (build it from the release tag; RELEASES.md)"
[ -n "$key_dir" ] || die "--key-dir <new directory outside any git repo> is required"
: "${GENESIS_TIME:?GENESIS_TIME (RFC 3339 UTC, e.g. 2026-10-15T12:00:00Z) is required: it is the devnet-1 launch time, a founder decision}"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

python3 - "$GENESIS_TIME" <<'PY' || die "GENESIS_TIME '$GENESIS_TIME' is not RFC 3339 UTC like 2026-10-15T12:00:00Z"
import datetime, re, sys
t = sys.argv[1]
if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z", t):
    sys.exit(1)
datetime.datetime.strptime(t[:19], "%Y-%m-%dT%H:%M:%S")
PY
if python3 -c 'import datetime,sys; u=datetime.timezone.utc; t=datetime.datetime.strptime(sys.argv[1][:19],"%Y-%m-%dT%H:%M:%S").replace(tzinfo=u); sys.exit(0 if t < datetime.datetime.now(u) else 1)' "$GENESIS_TIME"; then
  echo "WARNING: GENESIS_TIME $GENESIS_TIME is in the past: the chain produces its first block as soon" >&2
  echo "  the validator starts. That is fine for devnet-1 if it is what you mean; a launch time is usually ahead." >&2
fi

case "$binary" in
  */*) ;;
  *) binary=$(command -v "$binary" 2>/dev/null) || die "binary not found on PATH: $binary" ;;
esac
if [ ! -f "$binary" ] || [ ! -x "$binary" ]; then die "binary not found or not executable: $binary"; fi
binary="$(cd "$(dirname "$binary")" && pwd -P)/$(basename "$binary")"
vhome=$(mktemp -d "${TMPDIR:-/tmp}/devnet-keys-version.XXXXXX")   # `version` writes a client config to its --home
bin_version=$("$binary" version --home "$vhome" 2>&1 | tail -1) || { rm -rf "$vhome"; die "$binary does not run ('version' failed)"; }
rm -rf "$vhome"

sha256_of() { # sha256sum is coreutils (Linux); macOS ships shasum instead
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
bin_sha=$(sha256_of "$binary")

# Whole numbers, normalised so "00" or "007" can't slip past as text; a gentx
# that `genesis validate` accepts but InitChain rejects is caught here instead
# (PR #5 review: moniker > 70 chars, min self-delegation > self-delegation and
# "00" all produced a genesis that verified and then panicked at InitChain).
norm_int() { # norm_int <value> <name>: prints the positive integer without leading zeros
  case "$1" in ""|*[!0-9]*) die "$2 '$1' must be a positive whole number" ;; esac
  local v; v=$(python3 -c 'import sys; print(int(sys.argv[1]))' "$1")
  [ "$v" != 0 ] || die "$2 must be greater than 0"
  printf '%s' "$v"
}
[ -z "$self_delegation" ] || self_delegation=$(norm_int "$self_delegation" --self-delegation)
min_self_delegation=$(norm_int "$min_self_delegation" --min-self-delegation)
# x/staking MaxMonikerLength = 70; an empty or whitespace-only moniker is refused too.
python3 - "$moniker" <<'PY' || die "--moniker must be 1-70 characters, not blank, no control characters (x/staking MaxMonikerLength)"
import sys
m = sys.argv[1]
sys.exit(0 if m.strip() and len(m) <= 70 and m.isprintable() else 1)
PY
python3 - "$commission_rate" "$commission_max_rate" "$commission_max_change_rate" <<'PY' || die "commission: need 0.05 <= rate <= max-rate <= 1 and 0 < max-change-rate <= max-rate (D10: min_commission_rate 5 %)"
import sys
from decimal import Decimal, InvalidOperation
try:
    r, m, c = (Decimal(x) for x in sys.argv[1:4])
except InvalidOperation:
    sys.exit(1)
sys.exit(0 if Decimal("0.05") <= r <= m <= 1 and 0 < c <= m else 1)
PY
python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$p2p_ip" 2>/dev/null \
  || die "--p2p-ip must be an IPv4 address, got '$p2p_ip'"

# The key directory: new, outside every git work tree (so no `git add .` can
# ever publish a key), created 0700.
case "$key_dir" in "~"/*) key_dir="$HOME/${key_dir#"~/"}" ;; esac
key_dir=${key_dir%/}
[ -n "$key_dir" ] || die "--key-dir must not be /"
parent=$(dirname "$key_dir")
[ -d "$parent" ] || die "parent directory of --key-dir does not exist: $parent (create it first)"
key_dir="$(cd "$parent" && pwd -P)/$(basename "$key_dir")"
if [ -e "$key_dir" ] || [ -L "$key_dir" ]; then
  die "$key_dir already exists; refusing to overwrite keys. Choose a new directory."
fi
d=$(dirname "$key_dir")
while :; do
  [ ! -e "$d/.git" ] || die "$key_dir would be inside the git work tree at $d; keys must live outside every repo"
  [ "$d" != / ] || break
  d=$(dirname "$d")
done
if command -v git >/dev/null 2>&1 && git -C "$(dirname "$key_dir")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "$key_dir would be inside a git work tree; keys must live outside every repo"
fi

# The repo side: this script writes devnet-1's first genesis; it never replaces one.
[ -f "$repo/$net/allocations.example.json" ] || die "$repo/$net/allocations.example.json not found"
for f in allocations.json genesis.json genesis.sha256 genesis.pre-gentx.json gentx; do
  [ ! -e "$repo/$net/$f" ] || die "$repo/$net/$f already exists. devnet-1 has a genesis (or a half-finished run): a reset is a founder decision (STATUS P30); remove the file only if you mean to replace it."
done

boot_kash=$(python3 -c 'import json,sys; print(sum(r["kash"] for r in json.load(open(sys.argv[1])) if r["note"].startswith("validator bootstrap")))' "$repo/$net/allocations.example.json")
liquid_default=1000
[ -n "$self_delegation" ] || self_delegation=$((boot_kash - liquid_default))
[ "$self_delegation" -le "$boot_kash" ] || die "--self-delegation $self_delegation KASH exceeds the validator's allocation ($boot_kash KASH)"
python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) <= int(sys.argv[2]) * 10**18 else 1)' "$min_self_delegation" "$self_delegation" \
  || die "--min-self-delegation ${min_self_delegation}esp exceeds the self-delegation (${self_delegation} KASH = ${self_delegation}000000000000000000esp): the validator could never be created"
[ "$self_delegation" -lt "$boot_kash" ] || echo "WARNING: the whole validator row is self-delegated; the operator account keeps 0 liquid KASH and cannot pay fees until another account funds it." >&2

# The consensus and p2p keys are plain files: keep them off synced folders.
case "$key_dir/" in
  "$HOME/Desktop/"*|"$HOME/Documents/"*|*"/Library/Mobile Documents/"*|*/Library/CloudStorage/*|*Dropbox*|*OneDrive*|*"Google Drive"*|*iCloud*)
    echo "WARNING: $key_dir looks like a cloud-synced folder (iCloud Desktop & Documents, Dropbox," >&2
    echo "  OneDrive, Google Drive). priv_validator_key.json is NOT encrypted; a synced copy is an" >&2
    echo "  unencrypted off-machine copy. Prefer e.g. ~/konstellation-keys/devnet-1. Ctrl-C to stop." >&2 ;;
esac

echo "== devnet-1 key ceremony"
echo "   binary        $binary"
echo "   version       $bin_version"
echo "   sha256        $bin_sha (host build: $(uname -s)/$(uname -m))"
echo "   genesis_time  $GENESIS_TIME"
echo "   key dir       $key_dir"
echo
echo "   The binary must be built from the release tag recorded in RELEASES.md: the"
echo "   genesis comes from its 'init' defaults."

# --- password ------------------------------------------------------------------
read_secret() { # read_secret <prompt>: one line from stdin, no echo on a terminal
  local s
  printf '%s' "$1" >&2
  IFS= read -r -s s || { echo >&2; die "no password given"; }
  echo >&2
  printf '%s' "$s"
}
echo
echo "Choose the keyring password (at least 8 characters). It encrypts every account"
echo "key in $key_dir/keyring-file. Store it in your password manager, NOT next to"
echo "the backup: without it the keyring cannot be opened."
pw=$(read_secret "Keyring password: ")
pw2=$(read_secret "Repeat password: ")
[ "$pw" = "$pw2" ] || die "passwords do not match"
unset pw2
# The SDK trims the password it reads, so leading/trailing whitespace would make
# the check below count characters the keyring never sees (PR #5 review).
case "$pw" in [[:space:]]*|*[[:space:]]) die "the password must not start or end with whitespace (the keyring trims it)" ;; esac
[ "${#pw}" -ge 8 ] || die "password must be at least 8 characters"

# --- keys ------------------------------------------------------------------------
umask 077
tmp=$(mktemp -d "${TMPDIR:-/tmp}/devnet-keys.XXXXXX")
cleanup() {
  local rc=$?
  rm -rf "$tmp"; rm -f "$repo/$net/genesis.pre-gentx.json"
  if [ "$rc" != 0 ] && [ -d "$key_dir" ]; then
    echo "devnet-keys: FAILED after creating $key_dir. Nothing was published; to start over," >&2
    echo "  delete $key_dir and, in $repo/$net, allocations.json, gentx/, genesis.json, genesis.sha256 (whichever exist)." >&2
  fi
}
trap cleanup EXIT
mkdir -m 0700 "$key_dir"
chome="$tmp/client-home"   # client config for keys/debug calls; deleted on exit

kr=(--keyring-backend file --keyring-dir "$key_dir")
quiet() { # quiet <description> <cmd...>: silent on success, output on failure (never secrets: see callers)
  local what=$1; shift
  if ! "$@" >"$tmp/out" 2>&1; then echo "$what failed:" >&2; cat "$tmp/out" >&2; exit 1; fi
}

# Account keys: eth_secp256k1, coin type 60 (the binary's defaults), so each one
# is also an EVM account. Names are the TOKENOMICS §7 buckets in the devnet-1
# example allocations, plus the validator operator and the circuit admin.
keys=(validator faucet circuit-admin team grants incentives community-pool treasury)
addrs=()   # addrs[i] is the address of keys[i] (bash 3.2 on macOS: no associative arrays)
first=1
for k in "${keys[@]}"; do
  # A new file keyring asks for the password twice; an existing one once.
  if [ "$first" = 1 ]; then input=$(printf '%s\n%s\n' "$pw" "$pw"); first=0
  else input=$(printf '%s\n' "$pw"); fi
  if ! out=$("$binary" keys add "$k" "${kr[@]}" --home "$chome" --no-backup --output json <<<"$input" 2>"$tmp/err"); then
    echo "keys add $k failed:" >&2; cat "$tmp/err" >&2; exit 1
  fi
  a=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["address"])' "$out")
  addrs+=("$a")
  printf '   key %-15s %s\n' "$k" "$a"
done
unset input out
addr_of() { local i; for i in "${!keys[@]}"; do if [ "${keys[$i]}" = "$1" ]; then echo "${addrs[$i]}"; return; fi; done; exit 1; }
admin=$(addr_of circuit-admin); faucet=$(addr_of faucet)

# Consensus key + p2p key: `init` writes priv_validator_key.json and node_key.json.
quiet "konstellationd init" "$binary" init "$moniker" --chain-id "$net" --home "$key_dir/validator"
node_id=$("$binary" comet show-node-id --home "$key_dir/validator")
cons_pub=$("$binary" comet show-validator --home "$key_dir/validator")
echo "   node id           $node_id"

# --- allocations.json: the example's rows, amounts and notes; real addresses ----
python3 - "$repo/$net/allocations.example.json" "$repo/$net/allocations.json" \
  "$(addr_of team)" "$(addr_of grants)" "$(addr_of incentives)" "$(addr_of community-pool)" \
  "$(addr_of treasury)" "$admin" "$(addr_of validator)" "$faucet" <<'PY'
import json, sys
src, dst, *a = sys.argv[1:]
# note prefix in allocations.example.json -> key
by_prefix = [
    ("founding team", a[0]),
    ("community: ecosystem", a[1]),
    ("community: user", a[2]),
    ("community: on-chain community pool", a[3]),
    ("treasury", a[4]),
    ("circuit super admin", a[5]),
    ("validator bootstrap", a[6]),
    ("liquidity", a[7]),
]
rows = json.load(open(src))
used = set()
for r in rows:
    hit = [i for i, (p, _) in enumerate(by_prefix) if r["note"].startswith(p)]
    if len(hit) != 1 or hit[0] in used:
        sys.exit(f"allocations.example.json row not mapped to exactly one key: {r['note']!r}")
    used.add(hit[0])
    r["address"] = by_prefix[hit[0]][1]
if len(used) != len(by_prefix):
    sys.exit("allocations.example.json is missing a bucket this script creates a key for")
if sum(r["kash"] for r in rows) != 1_000_000_000:
    sys.exit("allocations do not sum to 1 000 000 000 KASH (TOKENOMICS §7)")
if sum(1 for r in rows if r["note"].startswith("validator bootstrap")) != 1:
    sys.exit("devnet-1 needs exactly one validator bootstrap row")
w = max(len(str(r["kash"])) for r in rows)
with open(dst, "w") as f:
    f.write("[\n" + ",\n".join(
        '  {{ "address": {}, "kash": {:>{w}}, "note": {} }}'.format(
            json.dumps(r["address"]), r["kash"], json.dumps(r["note"], ensure_ascii=False), w=w)
        for r in rows) + "\n]\n")
PY
chmod 0644 "$repo/$net/allocations.json"
echo "== wrote $net/allocations.json"

# --- ceremony ----------------------------------------------------------------------
gen() { GENESIS_TIME="$GENESIS_TIME" "$repo/scripts/gen-genesis.sh" "$net" --binary "$binary" "$@"; }

gen --pre-gentx
cp "$repo/$net/genesis.pre-gentx.json" "$key_dir/validator/config/genesis.json"
mkdir -p "$key_dir/gentx"
if ! "$binary" genesis gentx validator "${self_delegation}000000000000000000esp" \
     "${kr[@]}" --home "$key_dir/validator" --chain-id "$net" --moniker "$moniker" \
     --commission-rate "$commission_rate" --commission-max-rate "$commission_max_rate" \
     --commission-max-change-rate "$commission_max_change_rate" \
     --min-self-delegation "$min_self_delegation" --ip "$p2p_ip" \
     --output-document "$key_dir/gentx/gentx-validator.json" \
     <<<"$pw" >"$tmp/out" 2>&1; then
  echo "genesis gentx failed:" >&2; cat "$tmp/out" >&2; exit 1
fi
unset pw
echo "== gentx: $self_delegation KASH self-delegated ($((boot_kash - self_delegation)) KASH liquid), commission $commission_rate (max $commission_max_rate, change $commission_max_change_rate/day), min self-delegation ${min_self_delegation}esp"

# The gentx is public (it is inside genesis.json anyway); publish it next to the
# genesis so anyone can re-run gen-genesis.sh and get the same sha256 (§6.2).
mkdir -p "$repo/$net/gentx"
cp "$key_dir/gentx/gentx-validator.json" "$repo/$net/gentx/"
chmod 0755 "$repo/$net/gentx"; chmod 0644 "$repo/$net/gentx/gentx-validator.json"
gen --gentxs "$repo/$net/gentx" --circuit-admin "$admin"
h1=$(cut -d' ' -f1 "$repo/$net/genesis.sha256")
cp "$repo/$net/genesis.json" "$tmp/genesis.first.json"
echo "== re-running gen-genesis.sh with the same inputs (reproducibility check)"
gen --gentxs "$repo/$net/gentx" --circuit-admin "$admin" >/dev/null
cmp -s "$tmp/genesis.first.json" "$repo/$net/genesis.json" || die "second gen-genesis.sh run differs from the first: genesis is not reproducible, do not publish it"
echo "   byte-identical: sha256 $h1"
chmod 0644 "$repo/$net/genesis.json" "$repo/$net/genesis.sha256"
cp "$repo/$net/genesis.json" "$key_dir/validator/config/genesis.json"

# verify.sh looks for `konstellationd` on PATH to run `genesis validate`.
mkdir -p "$tmp/bin"; ln -s "$binary" "$tmp/bin/konstellationd"
PATH="$tmp/bin:$PATH" "$repo/scripts/verify.sh" "$net"

# --- public record + instructions --------------------------------------------------
faucet_hex=$("$binary" debug addr "$faucet" --home "$chome" | sed -n 's/^Address hex: //p')
{
  echo "devnet-1 key ceremony, $(date -u +%Y-%m-%dT%H:%M:%SZ). Everything in this file is PUBLIC."
  echo "binary         $bin_version  sha256 $bin_sha ($(uname -s)/$(uname -m))"
  echo "genesis_time   $GENESIS_TIME"
  echo "genesis sha256 $h1"
  echo "validator      moniker $moniker, node id $node_id"
  echo "consensus key  $cons_pub"
  for i in "${!keys[@]}"; do printf 'account %-15s %s\n' "${keys[$i]}" "${addrs[$i]}"; done
  echo "faucet EVM address $faucet_hex"
} > "$key_dir/PUBLIC.txt"
chmod 0600 "$key_dir/PUBLIC.txt"

cat <<EOF

== done. devnet-1 genesis: sha256 $h1

BACK UP NOW: the whole directory
    $key_dir
  keyring-file/                        8 account keys, encrypted with your password
                                       (validator, faucet, circuit-admin, team, grants,
                                       incentives, community-pool, treasury). No mnemonic
                                       was shown or saved: this directory + the password
                                       IS the backup.
  validator/config/priv_validator_key.json   consensus key, NOT encrypted
  validator/config/node_key.json             p2p identity, NOT encrypted
  gentx/, PUBLIC.txt                   public (addresses, node id, hashes)
Keep one copy on this PC and an ENCRYPTED copy off the machine (STATUS P29), e.g.
    tar -C "$(dirname "$key_dir")" -czf - "$(basename "$key_dir")" | gpg --symmetric --cipher-algo AES256 -o devnet-1-keys.tgz.gpg
  (or 'age -p'), on a USB drive / another location. Losing both = a new devnet genesis.

VALIDATOR SERVER (server 1) gets exactly two files, into <node home>/config/, mode 0600:
    validator/config/priv_validator_key.json
    validator/config/node_key.json
  Never run a second node with that priv_validator_key.json (ENGINEERING.md §2.7).
  Nothing else from this directory goes to any server, and no keyring goes there.

FAUCET: the service reads the faucet key's EVM private key from FAUCET_PRIVATE_KEY
  (faucet README, "Key handling"). Install it only when you deploy the faucet, with
    $repo/scripts/devnet-faucet-key.sh --binary "$binary" \\
      --key-dir "$key_dir" --to <ssh host>:<faucet env file>
  It exports the key locally first (a throwaway export password, then the keyring
  password), refuses anything that is not a 64-hex key, then replaces only the
  FAUCET_PRIVATE_KEY= line in the env file over ssh; the key never reaches the
  screen, an argument list or shell history. Faucet account: $faucet / $faucet_hex

NEXT, in $repo:
  1. git status: the new files are devnet-1/allocations.json, devnet-1/gentx/,
     devnet-1/genesis.json and devnet-1/genesis.sha256 (public addresses, the
     signed gentx and hashes; no key material). Anyone can reproduce the hash:
       GENESIS_TIME=$GENESIS_TIME scripts/gen-genesis.sh devnet-1 \\
         --gentxs devnet-1/gentx --circuit-admin $admin --binary <konstellationd at the tag>
  2. Record the release in RELEASES.md (version, linux-amd64 sha256).
  3. Commit those files together and open the PR; CI runs scripts/verify.sh.
  4. Fill devnet-1/README.md's TBDs (genesis, binary) in the same PR.
  Record addresses where the team expects them (PUBLIC.txt has them all).
EOF
