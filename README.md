# networks

Genesis files, peers and upgrade instructions for every Konstellation network.
Public. This is what an operator downloads and verifies against; nothing here
is executable and nothing here should ever be edited by hand once published.

Read the org's `ENGINEERING.md` first (§6.2 is this repo's layout, §9.4 how
upgrades are coordinated, §18 what differs between the networks).

## Networks

Three networks, one binary (D7, re-decided 2026-09-29). All validators at
genesis are foundation-run; anyone else becomes a validator only after
genesis, through the D16 `x/circuit` admission procedure — never by gentx.

| Directory | Chain-id / EIP-155 | For | Launch validators | Binary |
|---|---|---|---|---|
| [`devnet-1/`](devnet-1/README.md) | `devnet-1` / 56672 | **dapp developers**: faucet-fed, rarely reset | 1 | same version as mainnet |
| [`testnet-1/`](testnet-1/README.md) | `testnet-1` / 56671 | **operators**: upgrade, halt and chaos drills, D16 admission rehearsals | 4, separate failure domains | new releases land here first |
| `konstellation-1/` | `konstellation-1` / 5667 | mainnet, created at the genesis ceremony (ENGINEERING.md §15 phase 8) | 4, separate failure domains | — |

`max_validators` is 30 on all three. Governance: mainnet has the D11 profile;
devnet-1 and testnet-1 get the fast testnet profile (the binary selects it for
every chain-id other than `konstellation-1`).

## Layout

```
networks/
├── devnet-1/                   # chain-id devnet-1, EIP-155 56672 (same files as testnet-1)
├── testnet-1/                  # chain-id testnet-1, EIP-155 56671
│   ├── chain.json              # cosmos chain-registry format (endpoints, versions)
│   ├── README.md               # how to use it, hardware, config
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
    ├── gen-genesis.sh          # reproducible genesis from binary + allocations + gentxs
    └── networks.sh             # known networks and their launch-validator counts (sourced)
```

## Invariants (checked by CI, `scripts/verify.sh`)

- `<net>/genesis.sha256` matches `<net>/genesis.json` (ENGINEERING.md §5.2).
- `chain_id` inside `genesis.json` and `chain.json` equals the directory name —
  genesis decides the network (ENGINEERING.md §1).
- A known network's `genesis.json` has exactly its launch-validator count of
  gentxs (devnet-1 1, testnet-1 and konstellation-1 4 — `scripts/networks.sh`);
  `gen-genesis.sh --gentxs` refuses any other count.
- `allocations.example.json` sums to the 1 B KASH of TOKENOMICS.md §7 and has
  one `validator bootstrap` entry per launch validator, together 120 M.
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
GENESIS_TIME=2026-10-01T12:00:00Z scripts/gen-genesis.sh testnet-1 --gentxs ./gentxs \
    --circuit-admin kons1...
scripts/verify.sh testnet-1
```

`--circuit-admin` is required for a final genesis. `init` closes validator
admission (`MsgCreateValidator` in `x/circuit`'s disable list, D16), and the
circuit super admin is the key that opens the window for each admission and trips
the breaker in an emergency. Without one, both would first need a governance
proposal. The admin must also have a row in the allocations: an address with no
balance has no account on chain and cannot sign. `verify.sh` checks that every
known network's genesis keeps the gate closed and names at least one super admin.
Who holds it: a single dev key on devnet-1; testnet-1 is undecided; the 3-of-5
operations multisig on mainnet.

Record the binary version and sha256 used in `RELEASES.md` in the same commit.

## Upgrades

Every release goes **testnet-1 → devnet-1 → konstellation-1**: testnet-1
first, devnet-1 1–2 weeks before mainnet (so dapp developers get warning),
then mainnet. Each network gets its own `<net>/upgrades/v<N>-<name>.md` (from
`templates/upgrade.md`).

Mainnet: signed release → upgrade file here → `MsgSoftwareUpgrade` at the halt
height → cosmovisor swaps. testnet-1: same file, applied with
`infra/ansible/upgrade.yml` **and** a governance proposal, so the gov path is
rehearsed (ENGINEERING.md §9.4). devnet-1: same file; full-node operators
stage the binary from it. Cosmovisor auto-download is **off** everywhere; operators stage the
binary by hand after checking the SHA256 in the upgrade file (ENGINEERING.md §9.2).
