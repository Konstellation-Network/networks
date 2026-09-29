# shellcheck shell=bash
# Sourced by gen-genesis.sh and verify.sh; not run on its own.
#
# The networks this repo publishes and how many launch validators (gentxs) each
# genesis carries — D7 as re-decided 2026-09-29 (Solana-style three networks,
# ENGINEERING.md §1, §18):
#   devnet-1         dapp-developer network, 1 foundation-run validator
#   testnet-1        ops/rehearsal network,  4 foundation-run validators
#   konstellation-1  mainnet,                4 foundation-run validators
# Further validators join only after genesis, through the D16 x/circuit
# admission procedure, so they are never gentxs.
#
# A chain-id not listed here gets no count check (behaviour unchanged for
# ad-hoc directories); add a row when a network is added.

# launch_validators <net>: prints the required gentx count, or nothing if <net>
# is not a known network.
launch_validators() {
  case "$1" in
    devnet-1)                  echo 1 ;;
    testnet-1|konstellation-1) echo 4 ;;
    *)                         ;;
  esac
}
