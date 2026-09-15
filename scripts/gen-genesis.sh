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
#   GENESIS_TIME=2026-10-01T12:00:00Z scripts/gen-genesis.sh testnet-1 \
#       [--allocations testnet-1/allocations.json] [--gentxs <dir>] \
#       [--binary /path/to/konstellationd] [--pre-gentx]
#
#   --allocations  JSON list of {"address","kash","note"}; amounts in whole KASH
#                  (1 KASH = 10^18 esp). Default: <net>/allocations.json.
#   --gentxs       directory of gentx-*.json from each launch validator.
#                  Omit with --pre-gentx to publish the allocation-only genesis
#                  that validators run `konstellationd genesis gentx` against.
#   --binary       konstellationd to use. Default: `konstellationd` on PATH.
#                  Record the binary's version + sha256 in RELEASES.md.
#   --pre-gentx    write <net>/genesis.pre-gentx.json instead of genesis.json
#                  and skip the sha256 (it is an intermediate artifact).
#
# Two-step ceremony (the SDK's standard flow):
#   1. --pre-gentx → commit genesis.pre-gentx.json → each validator: add it as
#      config/genesis.json, `genesis gentx <key> <amount>esp --chain-id <net>
#      --commission-rate ≥0.05 --min-self-delegation ...`, send back the gentx.
#   2. --gentxs <dir> → genesis.json + genesis.sha256 → commit → publish hash.
set -euo pipefail

cd "$(dirname "$0")/.."

net=${1:-}; [ -n "$net" ] || { echo "usage: GENESIS_TIME=<rfc3339> $0 <net> [options]" >&2; exit 2; }
shift
allocations="$net/allocations.json"; gentxs=""; binary="konstellationd"; pre_gentx=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allocations) allocations=$2; shift 2 ;;
    --gentxs)      gentxs=$2; shift 2 ;;
    --binary)      binary=$2; shift 2 ;;
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
if [ -n "$gentxs" ]; then
  gentx_files=("$gentxs"/*.json)
  [ -e "${gentx_files[0]}" ] || { echo "no *.json gentxs in $gentxs" >&2; exit 2; }
fi
mkdir -p "$net"

home=$(mktemp -d "${TMPDIR:-/tmp}/gen-genesis.XXXXXX")
trap 'rm -rf "$home"' EXIT

echo "== binary: $("$binary" version 2>/dev/null | tail -1) ($(command -v "$binary"))"

# 1. Chain defaults. `init` with a real network's chain-id writes every module's
#    genesis from app.DefaultGenesis (esp everywhere, D10/D11 params, the
#    preinstalls), so nothing here is patched by hand.
"$binary" init "genesis-$net" --chain-id "$net" --home "$home" >/dev/null 2>&1

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
  "$binary" genesis collect-gentxs --home "$home" >/dev/null 2>&1
fi

# 4. Fix genesis_time (init stamps "now", which would make the file
#    non-reproducible) and validate.
python3 - "$home/config/genesis.json" "$GENESIS_TIME" <<'PY'
import json, sys
p, t = sys.argv[1], sys.argv[2]
g = json.load(open(p))
g["genesis_time"] = t
with open(p, "w") as f:
    json.dump(g, f, indent=2, sort_keys=True)
    f.write("\n")
PY
"$binary" genesis validate "$home/config/genesis.json" --home "$home" >/dev/null 2>&1 \
  || { echo "genesis validate failed:" >&2; "$binary" genesis validate "$home/config/genesis.json" --home "$home"; exit 1; }
echo "== genesis validate: ok (genesis_time $GENESIS_TIME)"

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
