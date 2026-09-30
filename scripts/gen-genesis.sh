#!/usr/bin/env bash
# Build <net>/genesis.json reproducibly from a konstellationd release, an
# allocation file and a directory of gentxs, then write <net>/genesis.sha256.
#
# The genesis is *not* hand-edited: everything comes from `konstellationd init`
# (chain defaults — ENGINEERING.md §6.1, STATUS.md §3), `genesis add-genesis-account`
# (allocations) and `genesis collect-gentxs` (launch validators). Anyone with the
# same binary, allocations, gentxs and GENESIS_TIME gets a byte-identical file,
# which is what lets operators verify the published sha256 independently
# (ENGINEERING.md §15 phase 8).
#
# Usage:
#   GENESIS_TIME=2026-10-01T12:00:00Z scripts/gen-genesis.sh <net> \
#       [--allocations <net>/allocations.json] [--gentxs <dir>] \
#       [--circuit-admin <kons1...>] [--binary /path/to/konstellationd] [--pre-gentx]
#
#   --allocations  JSON list of {"address","kash","note"}; amounts in whole KASH
#                  (1 KASH = 10^18 esp). Default: <net>/allocations.json.
#   --gentxs       directory of gentx-*.json from each launch validator.
#                  For a known network the count is enforced
#                  (scripts/networks.sh: devnet-1 1, testnet-1 and
#                  konstellation-1 4 — D7 re-decided 2026-09-29).
#                  Omit with --pre-gentx to publish the allocation-only genesis
#                  that validators run `konstellationd genesis gentx` against.
#   --circuit-admin  the x/circuit super admin (LEVEL_SUPER_ADMIN in
#                  app_state.circuit.account_permissions). Required for a
#                  final genesis (--gentxs). `init` closes validator admission
#                  (MsgCreateValidator in disabled_type_urls, D16); without a
#                  super admin, every admission window and every emergency trip
#                  would first need a governance proposal (STATUS P28).
#                  devnet-1: a single dev key (decided 2026-09-30); mainnet:
#                  the 3-of-5 operations multisig (ENGINEERING.md §13.1, §18).
#   --binary       konstellationd to use. Default: `konstellationd` on PATH.
#                  Record the binary's version + sha256 in RELEASES.md.
#   --pre-gentx    write <net>/genesis.pre-gentx.json instead of genesis.json
#                  and skip the sha256 (it is an intermediate artifact).
#
# Two-step ceremony (the SDK's standard flow):
#   1. --pre-gentx → commit genesis.pre-gentx.json → each launch validator (all
#      foundation-run, D7): add it as config/genesis.json, `genesis gentx <key>
#      <amount>esp --chain-id <net> --commission-rate ≥0.05
#      --min-self-delegation ...`, hand back the gentx.
#   2. --gentxs <dir> → genesis.json + genesis.sha256 → commit → publish hash.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/networks.sh
. scripts/networks.sh

net=${1:-}; [ -n "$net" ] || { echo "usage: GENESIS_TIME=<rfc3339> $0 <net> [options]" >&2; exit 2; }
shift
net=${net%/}
case "$net" in
  ""|*/*|.*) echo "'$net' is not a plain network directory name (it becomes the chain-id)" >&2; exit 2 ;;
esac
allocations="$net/allocations.json"; gentxs=""; binary="konstellationd"; pre_gentx=0; circuit_admin=""
while [ $# -gt 0 ]; do
  case "$1" in
    --allocations|--gentxs|--binary|--circuit-admin)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "$1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --allocations) allocations=$2; shift 2 ;;
    --gentxs)      gentxs=$2; shift 2 ;;
    --binary)      binary=$2; shift 2 ;;
    --circuit-admin) circuit_admin=$2; shift 2 ;;
    --pre-gentx)   pre_gentx=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

: "${GENESIS_TIME:?GENESIS_TIME (RFC 3339, e.g. 2026-10-01T12:00:00Z) is required so the output is reproducible}"
[ -f "$allocations" ] || { echo "allocations file not found: $allocations" >&2; exit 2; }
command -v "$binary" >/dev/null 2>&1 || { echo "binary not found: $binary" >&2; exit 2; }
if [ "$pre_gentx" = 0 ] && [ -z "$gentxs" ]; then
  echo "either --gentxs <dir> or --pre-gentx is required (a final genesis needs launch validators)" >&2; exit 2
fi
if [ "$pre_gentx" = 0 ] && [ -z "$circuit_admin" ]; then
  echo "--circuit-admin <kons1...> is required for a final genesis: init closes validator" >&2
  echo "admission (D16) and nobody could open it without a governance proposal (STATUS P28)" >&2
  exit 2
fi
if [ -n "$circuit_admin" ]; then
  case "$circuit_admin" in
    kons1*) ;;
    *) echo "--circuit-admin must be a kons1... account address, got '$circuit_admin'" >&2; exit 2 ;;
  esac
  # The binary checks the bech32 checksum; a typo here would otherwise only
  # surface when the admin first tries to sign.
  if ! "$binary" debug addr "$circuit_admin" >/dev/null 2>&1; then
    echo "--circuit-admin '$circuit_admin' is not a valid bech32 address" >&2; exit 2
  fi
fi
if [ -n "$gentxs" ]; then
  gentx_files=("$gentxs"/*.json)
  [ -e "${gentx_files[0]}" ] || { echo "no *.json gentxs in $gentxs" >&2; exit 2; }
  want=$(launch_validators "$net")
  if [ -n "$want" ] && [ "${#gentx_files[@]}" != "$want" ]; then
    echo "$net launches with $want validator(s) (D7, scripts/networks.sh); $gentxs has ${#gentx_files[@]} gentxs" >&2
    exit 2
  fi
fi
mkdir -p "$net"

home=$(mktemp -d "${TMPDIR:-/tmp}/gen-genesis.XXXXXX")
trap 'rm -rf "$home"' EXIT

echo "== binary: $("$binary" version 2>/dev/null | tail -1) ($(command -v "$binary"))"

# 1. Chain defaults. `init` with a real network's chain-id writes every module's
#    genesis from app.DefaultGenesis (esp everywhere, D10/D11 params, the
#    preinstalls), so nothing here is patched by hand.
run() { # run <description> <cmd...>: quiet on success, full output on failure
  local what=$1; shift
  local out
  if ! out=$("$@" 2>&1); then
    echo "$what failed:" >&2; echo "$out" >&2; exit 1
  fi
}
run "konstellationd init" "$binary" init "genesis-$net" --chain-id "$net" --home "$home"

# 2. Allocations. Whole KASH in the file, esp on chain: 1 KASH = 10^18 esp.
#    The shape must follow TOKENOMICS.md §7 (see <net>/README.md for the
#    testnet mapping); this script only enforces that it sums to the genesis
#    supply there.
total=$(python3 - "$allocations" <<'PY'
import json, sys
allocs = json.load(open(sys.argv[1]))
total = 0
seen = set()
for a in allocs:
    addr, kash = a["address"], a["kash"]
    if not addr or addr in seen:
        sys.exit(f"bad or duplicate address in allocation {a!r}")
    if not isinstance(kash, int) or kash <= 0:
        sys.exit(f"kash must be a positive integer (whole KASH) in {a!r}")
    seen.add(addr); total += kash
print(total)
PY
)
# The super admin signs txs, so it must exist on chain from block 1: an address
# with no balance has no account, and every tx from it fails with "account ...
# not found" — the admission window and an emergency trip would both wait on
# someone funding it first. Found by the P28 live-node test, 2026-09-30.
if [ -n "$circuit_admin" ] && ! python3 -c 'import json,sys; sys.exit(0 if any(a["address"]==sys.argv[2] for a in json.load(open(sys.argv[1]))) else 1)' "$allocations" "$circuit_admin"; then
  echo "--circuit-admin $circuit_admin has no allocation in $allocations: it would not exist" >&2
  echo "on chain and could not sign. Give it a row (a small amount for fees, from the treasury bucket)." >&2
  exit 2
fi
expected_supply=1000000000
if [ "$total" != "$expected_supply" ]; then
  echo "allocations sum to $total KASH, TOKENOMICS.md §7 genesis supply is $expected_supply KASH" >&2
  exit 1
fi
while IFS=$'\t' read -r addr kash note; do
  "$binary" genesis add-genesis-account "$addr" "${kash}000000000000000000esp" --home "$home" >/dev/null
  echo "   $addr  $kash KASH  $note"
done < <(python3 -c 'import json,sys; [print(a["address"], a["kash"], a.get("note",""), sep="\t") for a in json.load(open(sys.argv[1]))]' "$allocations")

# 3. Launch validators.
if [ -n "$gentxs" ]; then
  mkdir -p "$home/config/gentx"
  cp "${gentx_files[@]}" "$home/config/gentx/"
  echo "== ${#gentx_files[@]} gentxs"
  run "genesis collect-gentxs" "$binary" genesis collect-gentxs --home "$home"
fi

# 4. Fix genesis_time (init stamps "now", which would make the file
#    non-reproducible), write the circuit super admin, and validate. The
#    disable list itself comes from `init` (konstellation PR #14); refuse a
#    binary that did not write it rather than patch it in here.
python3 - "$home/config/genesis.json" "$GENESIS_TIME" "$circuit_admin" <<'PY'
import json, sys
p, t, admin = sys.argv[1], sys.argv[2], sys.argv[3]
g = json.load(open(p))
g["genesis_time"] = t
circuit = g["app_state"]["circuit"]
gate = "/cosmos.staking.v1beta1.MsgCreateValidator"
if circuit.get("disabled_type_urls") != [gate]:
    sys.exit(f"init wrote circuit disabled_type_urls {circuit.get('disabled_type_urls')!r}, "
             f"expected [{gate!r}] (D16); is this binary older than konstellation PR #14?")
if admin:
    circuit["account_permissions"] = [
        {"address": admin, "permissions": {"level": "LEVEL_SUPER_ADMIN", "limit_type_urls": []}}
    ]
with open(p, "w") as f:
    json.dump(g, f, indent=2, sort_keys=True)
    f.write("\n")
PY
run "genesis validate" "$binary" genesis validate "$home/config/genesis.json" --home "$home"
echo "== genesis validate: ok (genesis_time $GENESIS_TIME)"
[ -z "$circuit_admin" ] || echo "== circuit super admin: $circuit_admin"

# 5. Publish into the repo.
if [ "$pre_gentx" = 1 ]; then
  cp "$home/config/genesis.json" "$net/genesis.pre-gentx.json"
  echo "== wrote $net/genesis.pre-gentx.json (validators gentx against this; not the final genesis)"
else
  cp "$home/config/genesis.json" "$net/genesis.json"
  if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum "$net/genesis.json" | cut -d' ' -f1)
  else h=$(shasum -a 256 "$net/genesis.json" | cut -d' ' -f1); fi
  printf '%s  genesis.json\n' "$h" > "$net/genesis.sha256"
  rm -f "$net/genesis.pre-gentx.json"
  echo "== wrote $net/genesis.json"
  echo "== sha256 $h"
  echo "   next: scripts/verify.sh $net, then commit both files together and record the"
  echo "   binary version/sha256 used above in RELEASES.md."
fi
