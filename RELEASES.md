# Releases and checksums

Every `konstellation` release tag that a network runs, with the SHA256 of the
Linux binary, in one place (ENGINEERING.md §5.2: *every release tag has a
checksum recorded in `networks`*). Operators and `infra`'s ansible
(`konstellationd_version` / `konstellationd_sha256`) take checksums from here,
never from a chat message or a guess.

Adding a row is part of the release checklist. The checksum is of the
**`linux-amd64` release asset** — `make build-linux` in `konstellation` at the
tag prints it (plain `make build` hashes a host-platform binary, which will never
match) — re-verified against the GitHub Release asset with `sha256sum`; the same value goes into the network's `upgrades/*.md` when the
release is an upgrade.

| Version | Date | Binary | SHA256 | Networks | Notes |
|---|---|---|---|---|---|
| _none yet_ | | | | | first release cut after `konstellation` Phase 2 (STATUS.md §5) |

Genesis files have their own hash next to them (`<net>/genesis.sha256`), verified
by CI on every commit.
