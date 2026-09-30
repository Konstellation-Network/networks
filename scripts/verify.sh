#!/usr/bin/env bash
# Verify every network directory in this repo. Run by CI on every push/PR and
# usable locally: `scripts/verify.sh` (all networks) or `scripts/verify.sh testnet-1`.
#
# Enforces ENGINEERING.md §5.2 "networks/<net>/genesis.sha256 matches genesis.json"
# plus the cheap consistency checks around it:
#   - genesis.json parses and its chain_id equals the directory name
#     (the chain-id in genesis decides the network — ENGINEERING.md §1)
#   - for a known network (scripts/networks.sh), genesis.json carries exactly
#     its launch-validator count of gentxs: devnet-1 1, testnet-1 and
#     konstellation-1 4 (D7, re-decided 2026-09-29)
#   - for a known network, genesis.json keeps validator admission closed and
#     openable: x/circuit disabled_type_urls is exactly [MsgCreateValidator]
#     (D16) and account_permissions holds at least one LEVEL_SUPER_ADMIN with a
#     kons1 address (STATUS P28)
#   - allocations.example.json, if present, is the TOKENOMICS.md §7 shape:
#     sums to 1 000 000 000 KASH and, for a known network, has one
#     "validator bootstrap ..." entry per launch validator summing to the
#     120 M bucket
#   - genesis.sha256 is `sha256sum -c` format and matches
#   - chain.json parses, chain_id equals the directory name, genesis_url points
#     at this repo's copy of genesis.json
#   - seeds.txt / persistent_peers.txt lines are `<node-id>@<host>:<port>`
#   - upgrades/*.md carry every field ENGINEERING.md §6.2 requires
#   - if `konstellationd` is on PATH, `konstellationd genesis validate` runs too
#     (CI cannot until a release exists; operators should run it locally).
#
# A directory without genesis.json is allowed (pre-genesis, chain.json only).
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/networks.sh
. scripts/networks.sh

# Where operators fetch from; chain.json's genesis_url must be exactly this path.
repo_raw="https://raw.githubusercontent.com/Konstellation-Network/networks/main"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }
ok()  { echo "ok:   $*"; }

if [ $# -gt 0 ]; then
  nets=()
  for n in "$@"; do
    n=${n%/}
    case "$n" in
      ""|*/*|.*) echo "FAIL: '$n' is not a plain network directory name" >&2; exit 1 ;;
    esac
    nets+=("$n")
  done
else
  nets=()
  for d in */; do
    d=${d%/}
    [ -f "$d/chain.json" ] || [ -f "$d/genesis.json" ] || continue
    nets+=("$d")
  done
fi

if [ ${#nets[@]} -eq 0 ]; then
  echo "no network directories found (nothing with chain.json or genesis.json)"
  exit 0
fi

# sha256sum is coreutils (CI, Linux operators); macOS ships shasum instead.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

json_get() { # json_get <file> <python expr on `d`>
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

check_peers_file() { # check_peers_file <file>
  local f=$1 n=0 bad=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}; line=${line//[[:space:]]/}
    [ -z "$line" ] && continue
    n=$((n+1))
    # host is a DNS name, an IPv4 literal, or a bracketed IPv6 literal.
    if ! [[ $line =~ ^[0-9a-f]{40}@([A-Za-z0-9.-]+|\[[0-9a-fA-F:]+\]):[0-9]{1,5}$ ]]; then
      err "$f: bad entry '$line' (want <40-hex-node-id>@<host>:<port>)"; bad=1
    fi
  done < "$f"
  if [ "$bad" = 0 ]; then ok "$f: $n entries"; fi
}

for net in "${nets[@]}"; do
  echo "== $net"
  [ -d "$net" ] || { err "$net: not a directory"; continue; }
  want_vals=$(launch_validators "$net")

  # --- chain.json -----------------------------------------------------------
  if [ -f "$net/chain.json" ]; then
    if ! python3 -m json.tool "$net/chain.json" >/dev/null 2>&1; then
      err "$net/chain.json: not valid JSON"
    else
      bad=0
      cid=$(json_get "$net/chain.json" 'd.get("chain_id","")')
      [ "$cid" = "$net" ] || { err "$net/chain.json: chain_id '$cid' != directory '$net'"; bad=1; }
      gurl=$(json_get "$net/chain.json" 'd.get("codebase",{}).get("genesis",{}).get("genesis_url","")')
      case "$gurl" in
        "$repo_raw/$net/genesis.json") ;;
        "") err "$net/chain.json: codebase.genesis.genesis_url is empty"; bad=1 ;;
        *) err "$net/chain.json: genesis_url '$gurl' != $repo_raw/$net/genesis.json"; bad=1 ;;
      esac
      if [ "$bad" = 0 ]; then ok "$net/chain.json"; fi
    fi
  else
    err "$net/chain.json: missing (ENGINEERING.md §6.2)"
  fi

  # --- genesis.json + genesis.sha256 ----------------------------------------
  if [ -f "$net/genesis.json" ]; then
    if ! python3 -m json.tool "$net/genesis.json" >/dev/null 2>&1; then
      err "$net/genesis.json: not valid JSON"
    else
      cid=$(json_get "$net/genesis.json" 'd.get("chain_id","")')
      if [ "$cid" = "$net" ]; then ok "$net/genesis.json: chain_id $cid"
      else err "$net/genesis.json: chain_id '$cid' != directory '$net'"; fi
      if [ -n "$want_vals" ]; then
        ngen=$(json_get "$net/genesis.json" 'len(((d.get("app_state") or {}).get("genutil") or {}).get("gen_txs") or [])')
        if [ "$ngen" = "$want_vals" ]; then ok "$net/genesis.json: $ngen gentxs"
        else err "$net/genesis.json: $ngen gentxs, $net launches with $want_vals validator(s) (scripts/networks.sh)"; fi
        if msg=$(python3 - "$net/genesis.json" 2>&1 <<'PY'
import json, sys
c = ((json.load(open(sys.argv[1])).get("app_state") or {}).get("circuit") or {})
gate = "/cosmos.staking.v1beta1.MsgCreateValidator"
if c.get("disabled_type_urls") != [gate]:
    sys.exit(f"circuit disabled_type_urls is {c.get('disabled_type_urls')!r}, want [{gate!r}] (D16)")
admins = [p.get("address", "") for p in c.get("account_permissions") or []
          if (p.get("permissions") or {}).get("level") == "LEVEL_SUPER_ADMIN"]
if not admins:
    sys.exit("circuit has no LEVEL_SUPER_ADMIN in account_permissions: admission could only be opened by governance (P28)")
bad = [a for a in admins if not a.startswith("kons1")]
if bad:
    sys.exit(f"circuit super admin(s) not kons1 addresses: {bad}")
print(f"admission gated, super admin {', '.join(admins)}")
PY
        ); then ok "$net/genesis.json: $msg"
        else err "$net/genesis.json: $msg"; fi
      fi
    fi
    if [ ! -f "$net/genesis.sha256" ]; then
      err "$net/genesis.sha256: missing"
    else
      # Exactly one line, `<hash>  genesis.json`, so operators can run
      # `sha256sum -c genesis.sha256` unchanged.
      if [ "$(wc -l < "$net/genesis.sha256" | tr -d ' ')" != 1 ] \
         || ! grep -Eq '^[0-9a-f]{64}  genesis\.json$' "$net/genesis.sha256"; then
        err "$net/genesis.sha256: must be exactly one line '<sha256>  genesis.json'"
      elif [ "$(cut -d' ' -f1 "$net/genesis.sha256")" = "$(sha256_of "$net/genesis.json")" ]; then
        ok "$net/genesis.sha256 matches genesis.json"
      else
        err "$net/genesis.sha256 does not match genesis.json (actual $(sha256_of "$net/genesis.json"))"
      fi
    fi
    if command -v konstellationd >/dev/null 2>&1; then
      # --home a throwaway dir: without it the binary writes ~/.konstellationd/config/*.toml.
      if konstellationd genesis validate "$net/genesis.json" --home "$(mktemp -d)" >/dev/null 2>&1; then
        ok "$net/genesis.json: konstellationd genesis validate"
      else
        err "$net/genesis.json: konstellationd genesis validate failed"
      fi
    else
      echo "skip: konstellationd not on PATH, 'genesis validate' not run"
    fi
  else
    if [ -f "$net/genesis.sha256" ]; then err "$net/genesis.sha256 exists without genesis.json"; fi
    echo "note: $net has no genesis.json yet"
  fi

  # --- allocations.example.json: TOKENOMICS.md §7 shape ---------------------
  if [ -f "$net/allocations.example.json" ]; then
    if msg=$(python3 - "$net/allocations.example.json" "$want_vals" 2>&1 <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
try:
    allocs = json.load(open(path))
except ValueError as e:
    sys.exit(f"not valid JSON: {e}")
if not isinstance(allocs, list):
    sys.exit("must be a JSON list of {address, kash, note}")
total, boot = 0, []
for a in allocs:
    kash = a.get("kash")
    if not isinstance(kash, int) or isinstance(kash, bool) or kash <= 0:
        sys.exit(f"kash must be a positive integer (whole KASH) in {a!r}")
    total += kash
    if a.get("note", "").startswith("validator bootstrap"):
        boot.append(kash)
if total != 1_000_000_000:
    sys.exit(f"sums to {total} KASH, TOKENOMICS.md §7 genesis supply is 1000000000")
if want:
    if len(boot) != int(want):
        sys.exit(f"{len(boot)} 'validator bootstrap' entries, network launches with {want} validator(s) (scripts/networks.sh)")
    if sum(boot) != 120_000_000:
        sys.exit(f"validator bootstrap entries sum to {sum(boot)} KASH, TOKENOMICS.md §7 bucket is 120000000")
print(f"{len(allocs)} entries, 1 B KASH, {len(boot)} validator bootstrap")
PY
    ); then ok "$net/allocations.example.json: $msg"
    else err "$net/allocations.example.json: $msg"; fi
  fi

  # --- peers ----------------------------------------------------------------
  for f in seeds.txt persistent_peers.txt; do
    if [ -f "$net/$f" ]; then check_peers_file "$net/$f"; fi
  done

  # --- upgrades/*.md: ENGINEERING.md §6.2 mandatory fields -------------------
  if [ -d "$net/upgrades" ]; then
    for u in "$net"/upgrades/*.md; do
      [ -e "$u" ] || continue
      bad=0
      for field in "Upgrade name" "Halt height" "Binary" "SHA256" "Config changes" "Rollback"; do
        grep -qi "^#* *$field\|^| *$field\|^\*\*$field" "$u" || { err "$u: missing '$field' section (ENGINEERING.md §6.2)"; bad=1; }
      done
      if [ "$bad" = 0 ]; then ok "$u"; fi
    done
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "verify: FAILED" >&2
  exit 1
fi
echo "verify: all checks passed"
