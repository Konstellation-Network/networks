# networks

Genesis files, peers and upgrade instructions for every Konstellation network.
Public. This is what an operator downloads and verifies against; nothing here
is executable and nothing here should ever be edited by hand once published.

Read the org's `ENGINEERING.md` first (§6.2 is this repo's layout, §9.4 how
upgrades are coordinated, §18 what differs between the two networks).

## Layout

```
networks/
├── testnet-1/                  # chain-id testnet-1, EIP-155 56671
│   ├── chain.json              # cosmos chain-registry format (endpoints, versions)
│   ├── README.md               # how to join, hardware, config
│   ├── allocations.example.json# TOKENOMICS.md §7 shape for scripts/gen-genesis.sh
│   ├── genesis.json            # (once cut) — never hand-edited
│   ├── genesis.sha256          # `sha256sum -c genesis.sha256`
│   ├── seeds.txt               # (once nodes exist) one <node-id>@<host>:<port> per line
│   ├── persistent_peers.txt
│   └── upgrades/               # one file per coordinated upgrade
├── konstellation-1/            # chain-id konstellation-1, EIP-155 5667 —
│                               # created at the mainnet genesis ceremony (§15 phase 8)
├── templates/upgrade.md        # copy for every <net>/upgrades/v<N>-<name>.md
├── RELEASES.md                 # binary version → sha256 ledger
└── scripts/
    ├── verify.sh               # what CI runs; run it before every commit
    └── gen-genesis.sh          # reproducible genesis from binary + allocations + gentxs
```

## Invariants (checked by CI, `scripts/verify.sh`)

- `<net>/genesis.sha256` matches `<net>/genesis.json` (ENGINEERING.md §5.2).
- `chain_id` inside `genesis.json` and `chain.json` equals the directory name —
  genesis decides the network (ENGINEERING.md §1).
- Peer files are `<40-hex-node-id>@<host>:<port>`, one per line.
- Every `upgrades/*.md` has the six sections ENGINEERING.md §6.2 requires
  (name, halt height, binary, SHA256, config changes, rollback).

## Cutting a genesis

Never edit `genesis.json` by hand. `scripts/gen-genesis.sh` runs
`konstellationd init` (chain defaults come from the binary — the same code path
every node uses), adds the allocations, collects gentxs, pins `genesis_time`, and
writes `genesis.json` + `genesis.sha256`. Same inputs ⇒ byte-identical output, so
any operator can reproduce the hash rather than trust it.

```sh
# 1. allocation-only genesis for validators to gentx against
GENESIS_TIME=2026-10-01T12:00:00Z scripts/gen-genesis.sh testnet-1 --pre-gentx
# 2. final genesis once the gentxs are in
GENESIS_TIME=2026-10-01T12:00:00Z scripts/gen-genesis.sh testnet-1 --gentxs ./gentxs
scripts/verify.sh testnet-1
```

Record the binary version and sha256 used in `RELEASES.md` in the same commit.

## Upgrades

Mainnet: signed release → `<net>/upgrades/v<N>-<name>.md` here (from
`templates/upgrade.md`) → `MsgSoftwareUpgrade` at the halt height → cosmovisor
swaps. Testnet: same file, applied with `infra/ansible/upgrade.yml` instead of a
proposal. Cosmovisor auto-download is **off** everywhere; operators stage the
binary by hand after checking the SHA256 in the upgrade file (ENGINEERING.md §9.2).
