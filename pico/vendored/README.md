# Vendored binaries live here — and only here

`pico.sh` stages its two runtime binaries from this directory. There are
**no runtime downloads anywhere in the launcher**: at deploy time the
stack runs from exactly the files committed in this repo, or it stops
with a clear error.

| File | Upstream | Version | sha256 |
|---|---|---|---|
| `Xray-linux-64.zip` | XTLS/Xray-core release | v26.10.31 | `e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214` |
| `cloudflared-linux-amd64` | cloudflare/cloudflared release | 2026.10.7 | `1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872` |
| `Xray-linux-arm64-v8a.zip` | XTLS/Xray-core release | v26.10.31 | `1811c8f1da0c3b6dc707ebaf1c8390e987ba39859a8f0a7aadd8526157f2ec8d` |
| `cloudflared-linux-arm64` | cloudflare/cloudflared release | 2026.10.7 | `3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775` |

All four digests were verified locally against fresh downloads from the
official GitHub releases on 2026-11-08, and are also pinned in `pico.sh`
itself. `pico.sh`
re-verifies the hash of the artifact for the host architecture on every
first run, before staging it into `$PICO_HOME/bin`.

To populate or refresh this directory (the project's only deliberate
network step, done before deployment, never during):

```sh
sh tools/fetch-binaries.sh          # both architectures
sh tools/fetch-binaries.sh x86_64   # or just one
```

Why vendor at all: the first live deployment (InstaBox S, 2026-11-08) was
nearly blocked because the launcher's first-run download of these exact
files hit a persistent HTTP 504 on the shared egress path — a step that
is invisible when it works and fatal when it doesn't. Deployment inputs
belong in the repo, under version control, verified against pinned
hashes — not fetched opportunistically at first boot.
