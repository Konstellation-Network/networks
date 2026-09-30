# devnet-1

**The network for dapp developers.** Deploy and test contracts here. devnet-1
runs the **same `konstellationd` version as mainnet** (`konstellation-1`), is
funded from a faucet, and is **rarely reset** — so what works here works on
mainnet, and your deployments stay put. It is not where the foundation drills
upgrades or breaks validators; that is [`testnet-1`](../testnet-1/README.md)
(D7, re-decided 2026-09-29).

**Status: pre-genesis.** No `genesis.json`, peers or endpoints yet. Items
marked **TBD** are filled in the commit that publishes the genesis.

| | |
|---|---|
| Cosmos chain-id | `devnet-1` |
| EIP-155 chain id | `56672` (lives in `app.toml` `[evm] evm-chain-id`; `init` writes it, the node refuses to start with any other value) |
| Bech32 prefix | `kons` |
| Token | KASH — base denom `esp`, 18 decimals (`1 KASH = 1000000000000000000esp`); no value, faucet-fed |
| Binary | `konstellationd` — the version mainnet runs, see `../RELEASES.md` (**TBD**) |
| Genesis | `genesis.json` + `genesis.sha256` — **TBD** |
| Validators | **1**, foundation-run |
| Faucet | **TBD** (`faucet` repo) |
| EVM JSON-RPC / Cosmos RPC / REST / gRPC | **TBD** — will be listed in `chain.json` `apis` |
| Explorer | **TBD** (Blockscout, `explorer` repo) |

Everything economic — issuance (D4), base-fee burn (D5), staking (D10),
community tax — is identical to mainnet. Governance uses the fast testnet
profile the binary selects for every chain-id other than `konstellation-1`:
voting period **2 h**, expedited **30 min**, deposits **10 / 50 KASH**
(ENGINEERING.md §18).

## Build a dapp

### Wallet

MetaMask / Rabby → add network:

| Field | Value |
|---|---|
| Network name | `Konstellation Devnet` |
| Chain ID | `56672` |
| Currency symbol | `KASH` (18 decimals) |
| RPC URL | **TBD** |
| Block explorer | **TBD** |

For code, the `chain-config` npm package exports these values; prefer it over
copying them by hand.

### Funds

Request KASH from the faucet (**TBD**). Devnet KASH has no value and is never
exchanged for mainnet KASH.

### Deploy

Any Ethereum toolchain works against the JSON-RPC endpoint (Foundry, Hardhat,
viem/ethers). Target EVM version **Prague** (D17; Osaka is not enabled).

```sh
forge create src/MyContract.sol:MyContract \
  --rpc-url <devnet-1 EVM JSON-RPC> --chain 56672 --private-key "$KEY" --broadcast
```

The canonical preinstalls (`Multicall3`, `Permit2`, `Create2Deployer`,
ERC-4337 `EntryPoint` v0.7 and v0.8 with their `SenderCreator`s) are live at
their mainnet-canonical addresses from block 1; the list is in the `contracts`
repo. `WKASH` is deployed post-genesis (address **TBD**).

### Upgrades and resets

devnet-1 follows mainnet's binary. A release reaches the networks in the order
**testnet-1 → devnet-1 → konstellation-1**, and devnet-1 is upgraded **1–2 weeks
before mainnet**, so a devnet upgrade is your warning that mainnet is about to
change: re-run your tests after each one. Upgrades are announced with a file in
`upgrades/` (halt height, binary, SHA256).

A reset wipes all state — contracts, balances, history. It is rare and
announced in advance; keep your deployment scripts, not just your addresses.

## Run a full node

Run your own node if you need an RPC without rate limits, archive/trace data,
or your own indexer. There is **one validator, run by the foundation**; there
is no gentx or validator path on devnet-1. `MsgCreateValidator` is disabled in
`x/circuit` from genesis (D16), so `create-validator` is refused. Operators who
want to rehearse validating should ask about the D16 admission drills on
`testnet-1`.

### Hardware

| Role | Spec |
|---|---|
| Full node | 8–16 vCPU, 32–64 GB RAM, 2–4 TB **local NVMe**, 1 Gbps |
| Archive node (`pruning = "nothing"`, tracing on) | same, disk grows without bound |

Disk is the bottleneck (IAVL commit latency is disk-bound; ENGINEERING.md §9.2).

### 1. Binary

Download the release asset that mainnet runs and verify it against
`../RELEASES.md`.

```sh
VERSION=<from RELEASES.md>
curl -fsSLO "https://github.com/Konstellation-Network/konstellation/releases/download/${VERSION}/konstellationd-${VERSION}-linux-amd64"
sha256sum -c <<< "<sha256 from RELEASES.md>  konstellationd-${VERSION}-linux-amd64"
```

### 2. Cosmovisor layout

Cosmovisor with auto-download **off**; upgrade binaries are staged by hand from
`upgrades/*.md`.

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
"$DAEMON_HOME/cosmovisor/genesis/bin/konstellationd" init <moniker> --chain-id devnet-1 --home "$DAEMON_HOME"
```

`init` writes a complete, correct `config.toml` / `app.toml` / `client.toml` for
this chain-id — every denom `esp`, `evm-chain-id = 56672`, `mempool.type = "app"`.
There is no `jq`/`sed` patching step; if a recipe tells you to patch those
values, it is wrong.

### 4. Genesis

Replace the placeholder genesis `init` wrote with the published one and verify
the hash **before** starting:

```sh
curl -fsSL -o "$DAEMON_HOME/config/genesis.json" \
  https://raw.githubusercontent.com/Konstellation-Network/networks/main/devnet-1/genesis.json
curl -fsSL https://raw.githubusercontent.com/Konstellation-Network/networks/main/devnet-1/genesis.sha256 \
  | (cd "$DAEMON_HOME/config" && sha256sum -c -)
"$DAEMON_HOME/cosmovisor/genesis/bin/konstellationd" genesis validate --home "$DAEMON_HOME"
```

### 5. Peers and config

`config.toml` `[p2p]`: `seeds` from `seeds.txt`, `persistent_peers` from
`persistent_peers.txt` (comma-joined). For an RPC node, check that `app.toml`
`[json-rpc]` has `enable = true` and the address you intend to expose.
Non-archive pruning (ENGINEERING.md §9.2):

```toml
pruning = "custom"
pruning-keep-recent = "100"
pruning-interval = "10"
```

State sync and snapshot sources: **TBD** (`snapshots.md`).

### 6. Start

```sh
cosmovisor run start --home "$DAEMON_HOME"
# elsewhere:
konstellationd status | jq .sync_info
```

## Genesis allocation

The `TOKENOMICS.md §7` shape (1 B KASH), filled with **test addresses**, same
as testnet-1 except that the whole 12 % bootstrap bucket (120 M) is
self-delegated by the single foundation validator. The faucet holds the 8 %
"liquidity & public distribution" bucket. See `allocations.example.json` and
`../scripts/gen-genesis.sh` (which refuses a devnet-1 genesis with other than
one gentx).

## Cutting the genesis (maintainers)

devnet-1's genesis is cut once, on the founder's PC, by
[`../scripts/devnet-keys.sh`](../scripts/devnet-keys.sh). It needs the release
binary, so the order is:

1. **Release tag** — the first signed `konstellation` release exists.
2. **Run the script** with `konstellationd` built from that tag on the PC
   (`make build` at the tag; the genesis comes from its `init` defaults, and
   `GENESIS_TIME` is the launch time, a founder decision):

   ```sh
   mkdir -p ~/konstellation-keys          # the parent; must not be inside a git repo
   GENESIS_TIME=<launch, e.g. 2026-10-15T12:00:00Z> scripts/devnet-keys.sh \
     --binary ~/src/konstellation/build/konstellationd \
     --key-dir ~/konstellation-keys/devnet-1
   ```

   It asks for a keyring password twice (keep it in a password manager, not
   with the backup). It refuses a key directory that exists or is inside a git
   work tree, and refuses to run if `devnet-1` already has an `allocations.json`,
   `gentx/` or `genesis.json` (a reset is STATUS P30). Avoid cloud-synced
   folders (iCloud Desktop & Documents, Dropbox): two of the keys are plain files.
3. **Commit** `allocations.json`, `gentx/`, `genesis.json` and `genesis.sha256`
   (public addresses, the signed gentx, hashes; the script prints the command
   that reproduces the hash) and fill this README's **TBD**s.
4. **Record** the binary in `../RELEASES.md` in the same PR.

What the key directory holds (created `0700`):

| Path | What | Where it goes |
|---|---|---|
| `keyring-file/` | 8 account keys, encrypted with the password: `validator` (operator), `faucet`, `circuit-admin`, `team`, `grants`, `incentives`, `community-pool`, `treasury` — one per row of `allocations.example.json` | stays on the PC; no mnemonic is shown or saved (`keys add --no-backup`), so this directory plus the password **is** the backup |
| `validator/config/priv_validator_key.json` | consensus key, **not encrypted** | **validator server (server 1)**, `<home>/config/`, mode `0600`; nowhere else, and never two nodes with it (ENGINEERING.md §2.7) |
| `validator/config/node_key.json` | p2p identity, not encrypted | validator server, with the key above |
| `gentx/`, `PUBLIC.txt` | the signed gentx; every address, node id and hash | public |

**Backup (STATUS P29):** the founder keeps the directory on the PC and an
**encrypted copy off the machine**, e.g.
`tar -czf - devnet-1 | gpg --symmetric --cipher-algo AES256 -o devnet-1-keys.tgz.gpg`
(or `age -p`). Losing both means a new devnet genesis.

**Faucet key:** the `faucet` service reads the faucet account's EVM private
key from `FAUCET_PRIVATE_KEY`. Export it only when deploying the faucet, piped
straight to where the service reads it:

```sh
konstellationd keys unsafe-export-eth-key faucet --keyring-backend file \
    --keyring-dir ~/konstellation-keys/devnet-1 \
  | ssh <faucet host> 'umask 077; { printf "FAUCET_PRIVATE_KEY="; cat; } > <faucet env file>'
```

It asks a throwaway export password (any 8+ characters) and then the keyring
password. The faucet holds the 80 M "liquidity" row; its README advises
topping the service's key up in tranches instead, which would need a separate
liquidity key (not done: the example allocations give the faucet the row).

Gentx defaults: the whole 120 M bootstrap row self-delegated, commission 5 %
(the D10 minimum; max 20 %, max change 1 %/day), `min-self-delegation` 1 esp,
and `127.0.0.1` as the IP in the gentx memo so no real address is published
(peering comes from `persistent_peers.txt`). Each is a flag; see
`scripts/devnet-keys.sh --help`.
