# testnet-1

**The operations and validator-rehearsal network.** Building a dapp? Use
[`devnet-1`](../devnet-1/README.md) — it runs the mainnet binary, is rarely
reset, and nothing on it gets drilled. testnet-1 is where the foundation
rehearses everything before it touches mainnet: it gets every new release
first, and it is where upgrade drills, halt-and-restart drills, chaos tests
(validators killed mid-block) and D16 validator admissions happen
(ENGINEERING.md §15 phase 5). Expect planned halts, forced upgrades and
deliberately broken validators. Upgrade order is **testnet-1 → devnet-1 →
konstellation-1** (D7, re-decided 2026-09-29).

**Status: pre-genesis.** No `genesis.json`, peers or endpoints yet — this page
describes how joining will work and is being written ahead of the network so
that the first operators can find its gaps (ENGINEERING.md §15 phases 5–6). Items
marked **TBD** are filled in the commit that publishes the genesis.

| | |
|---|---|
| Cosmos chain-id | `testnet-1` |
| EIP-155 chain id | `56671` (lives in `app.toml` `[evm] evm-chain-id`; `init` writes it, the node refuses to start with any other value) |
| Bech32 prefix | `kons` |
| Token | KASH — base denom `esp`, 18 decimals (`1 KASH = 1000000000000000000esp`) |
| Binary | `konstellationd` — version **TBD**, see `../RELEASES.md` |
| Genesis | `genesis.json` + `genesis.sha256` — **TBD** |
| Faucet | **TBD** (`faucet` repo) |
| EVM JSON-RPC / Cosmos RPC / REST / gRPC | **TBD** — will be listed in `chain.json` `apis` |
| Explorer | **TBD** (Blockscout, `explorer` repo) |

Governance on this network is deliberately fast (ENGINEERING.md §18): voting
period **2 h**, expedited **30 min**, deposits **10 / 50 KASH**. Everything
economic — issuance (D4), base-fee burn (D5), staking (D10), community tax — is
identical to mainnet, because testnet-1 exists to measure what mainnet will do.
`blocks_per_year` is the one parameter that will be recalibrated from this
network's observed block time before mainnet.

## Hardware

From ENGINEERING.md §9.2. Disk is the bottleneck: IAVL commit latency is
disk-bound, so network block storage costs block time.

| Role | Spec |
|---|---|
| Validator / sentry | 8–16 vCPU, 32–64 GB RAM, 2–4 TB **local NVMe**, 1 Gbps |
| Archive node (`pruning = "nothing"`, tracing on) | same, disk grows without bound |

## Join as a full node

### 1. Binary

Download the release asset and verify it against `../RELEASES.md`. Never build
on the machine that runs the node (ENGINEERING.md §2.6).

```sh
VERSION=<from RELEASES.md>
curl -fsSLO "https://github.com/Konstellation-Network/konstellation/releases/download/${VERSION}/konstellationd-${VERSION}-linux-amd64"
sha256sum -c <<< "<sha256 from RELEASES.md>  konstellationd-${VERSION}-linux-amd64"
```

### 2. Cosmovisor layout

Cosmovisor with auto-download **off**; upgrade binaries are staged by hand from
`upgrades/*.md` (ENGINEERING.md §9.2).

```sh
export DAEMON_NAME=konstellationd
export DAEMON_HOME=$HOME/.konstellationd
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
export DAEMON_RESTART_AFTER_UPGRADE=true
mkdir -p "$DAEMON_HOME/cosmovisor/genesis/bin"
install -m 0755 konstellationd-${VERSION}-linux-amd64 "$DAEMON_HOME/cosmovisor/genesis/bin/konstellationd"
ln -s "$DAEMON_HOME/cosmovisor/genesis" "$DAEMON_HOME/cosmovisor/current"
```

### 3. Init

```sh
"$DAEMON_HOME/cosmovisor/genesis/bin/konstellationd" init <moniker> --chain-id testnet-1 --home "$DAEMON_HOME"
```

`init` writes a complete, correct `config.toml` / `app.toml` / `client.toml` for
this chain-id — every denom `esp`, `evm-chain-id = 56671`, `mempool.type = "app"`.
There is no `jq`/`sed` patching step; if a recipe tells you to patch those
values, it is wrong. `--default-denom` is accepted only as `esp`.

### 4. Genesis

Replace the placeholder genesis `init` wrote with the published one and verify
the hash **before** starting:

```sh
curl -fsSL -o "$DAEMON_HOME/config/genesis.json" \
  https://raw.githubusercontent.com/Konstellation-Network/networks/main/testnet-1/genesis.json
curl -fsSL https://raw.githubusercontent.com/Konstellation-Network/networks/main/testnet-1/genesis.sha256 \
  | (cd "$DAEMON_HOME/config" && sha256sum -c -)
"$DAEMON_HOME/cosmovisor/genesis/bin/konstellationd" genesis validate --home "$DAEMON_HOME"
```

### 5. Peers and config

`config.toml` `[p2p]`: `seeds` from `seeds.txt`, `persistent_peers` from
`persistent_peers.txt` (comma-joined). Set `prometheus = true` under
`[instrumentation]` (`init` leaves it `false`; metrics on 26660 are what the
alerting in ENGINEERING.md §9.2 reads).

Recommended `app.toml` for a non-archive node (ENGINEERING.md §9.2):

```toml
pruning = "custom"
pruning-keep-recent = "100"
pruning-interval = "10"
```

State sync and snapshot sources: **TBD** (`snapshots.md`, once archive nodes exist).

### 6. Start

```sh
cosmovisor run start --home "$DAEMON_HOME"
# elsewhere:
konstellationd status | jq .sync_info
```

A systemd unit is in `infra/ansible/roles/cosmovisor/templates/cosmovisor.service.j2`
(private repo) if you want the reference shape.

## Validators

The genesis set is **4 validators, all foundation-run**, each in a separate
failure domain (D7, re-decided 2026-09-29; which providers is not decided yet).
They are the only gentxs in the genesis — there is no gentx path for anyone
else, and `scripts/gen-genesis.sh` refuses a testnet-1 genesis with any other
count.

**Admission is permissioned (D16).** `MsgCreateValidator` is disabled in
`x/circuit` from genesis, so `konstellationd tx staking create-validator` is
refused for everyone. An operator is admitted only through the D16 procedure:
the circuit super admin re-enables the message for a window of a few blocks,
the admitted operator submits `create-validator` from a synced node, and the
message is disabled again (`infra/runbooks/validator-admission.md`). testnet-1
exists partly to rehearse exactly this before it is ever done on mainnet
(ENGINEERING.md §15 phases 5–6). If you are asked to take part in an admission
drill you will be told the window; do not pre-sign and broadcast early — a
`create-validator` sent before the window opens is refused and must be
re-signed.

Staking parameters (D10): `min_commission_rate` **5 %**, `max_validators`
**30**, unbonding **21 days**, downtime slash **0.01 %**, double-sign slash
**5 %** with permanent jail.

**Run validators behind sentries** (`pex = false`, `persistent_peers` = your
sentries only, no public IP; sentries carry your node id in `private_peer_ids`)
and sign with horcrux or tmkms. **Never run two nodes with the same
`priv_validator_key.json`** — restoring from a snapshot that includes the key,
a warm standby, or "just for a minute" all count (ENGINEERING.md §2.7). Testnet
has no money at stake; the habit is the point.

## Wallets and dapps

Dapp development belongs on [`devnet-1`](../devnet-1/README.md) (EIP-155
`56672`); testnet-1 is halted and upgraded on purpose. For testing against the
next release before it reaches devnet-1: MetaMask / Rabby network name
`Konstellation Testnet`, chain id `56671`, currency `KASH`, RPC URL **TBD**,
explorer **TBD**. Canonical preinstalls
(`Multicall3`, `Permit2`, `Create2Deployer`, ERC-4337 `EntryPoint` v0.7 and v0.8
with their `SenderCreator`s) are live at their mainnet-canonical addresses from
block 1; the list is in the `contracts` repo. `WKASH` is deployed post-genesis
(address **TBD**).

## Genesis allocation

The `TOKENOMICS.md §7` shape (1 B KASH), filled with **test addresses**; the
faucet holds the 8 % "liquidity & public distribution" bucket and the four
launch validators each self-delegate 30 M of the 12 % bootstrap bucket. See
`allocations.example.json` and `../scripts/gen-genesis.sh`. Nothing on this
network is vesting-locked — the D12 vesting contracts are exercised here as
ordinary contract deployments, not as genesis state.
