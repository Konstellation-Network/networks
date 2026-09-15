<!--
Copy to <net>/upgrades/v<N>-<name>.md and fill in every section. This file is the
public artifact operators read during a coordinated upgrade (ENGINEERING.md §6.2,
§9.4); scripts/verify.sh checks the six mandatory sections are present.
infra/ansible/upgrade.yml reads the binary URL and SHA256 from here.
-->

# Upgrade name: `<name>`

The `MsgSoftwareUpgrade` plan name. Must match the name the binary registers;
cosmovisor looks for `$DAEMON_HOME/cosmovisor/upgrades/<name>/bin/konstellationd`.

## Halt height

| | |
|---|---|
| Halt height | `<height>` |
| Expected time (UTC) | `<YYYY-MM-DD HH:MM>` at the current block time — **height is authoritative** |
| Governance proposal | `<proposal id / link>` (mainnet) or `ansible/upgrade.yml` run (testnet) |
| State-breaking | yes / no |

## Binary

| | |
|---|---|
| Version | `v<X.Y.Z>` |
| Release | `https://github.com/Konstellation-Network/konstellation/releases/tag/v<X.Y.Z>` |
| Download | `https://github.com/Konstellation-Network/konstellation/releases/download/v<X.Y.Z>/konstellationd-v<X.Y.Z>-linux-amd64` |
| Go toolchain | `go<X.Y.Z>` (the `toolchain` line in `go.mod` at the tag) |

## SHA256

```
<sha256>  konstellationd-v<X.Y.Z>-linux-amd64
```

Also recorded in `RELEASES.md`. Verify **before** staging (ENGINEERING.md §2.6 —
never build on a validator):

```sh
sha256sum -c <<< "<sha256>  konstellationd-v<X.Y.Z>-linux-amd64"
```

## Config changes

`config.toml` / `app.toml` keys that must change with this release, or "none".

| File | Key | Old | New | Why |
|---|---|---|---|---|
| `app.toml` | `<key>` | `<old>` | `<new>` | |

## Rollback

What to do if the network fails to produce blocks after the halt height:
which binary to restore to `cosmovisor/current`, whether a data snapshot from
before the halt height is needed (state-breaking upgrades: **yes**, take one
before the halt), and where coordination happens.

## Staging steps (operators)

```sh
# 1. download + verify
curl -fsSLO "<download url>"
sha256sum -c <<< "<sha256>  konstellationd-v<X.Y.Z>-linux-amd64"
# 2. stage for cosmovisor — auto-download is OFF (ENGINEERING.md §9.2)
mkdir -p "$DAEMON_HOME/cosmovisor/upgrades/<name>/bin"
install -m 0755 konstellationd-v<X.Y.Z>-linux-amd64 "$DAEMON_HOME/cosmovisor/upgrades/<name>/bin/konstellationd"
"$DAEMON_HOME/cosmovisor/upgrades/<name>/bin/konstellationd" version
# 3. nothing else: cosmovisor swaps at the halt height and restarts the node
```
