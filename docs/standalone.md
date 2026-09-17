# TX-Node standalone maintenance policy

TX-Node is maintained as an independent project. It originated from Xboard-Node and keeps Xboard panel compatibility where that compatibility is part of the protocol surface, but TX-Node no longer treats upstream synchronization as its development model.

## Source of truth

- `PaiMonCai/TX-Node` is the source of truth for development and releases.
- `main` is the product mainline.
- Releases are created from semantic `v*` tags only.
- Upstream repositories are references for fixes and ideas, not merge targets.

## Upstream changes

Do not periodically merge an upstream branch into TX-Node. For a useful upstream change: inspect the diff, confirm it applies, port the minimal change, adapt it to TX-Node, run tests, and release it under the TX-Node version line.

## Compatibility boundary

The following are compatibility surfaces, not branding leftovers:

- Xboard panel API paths such as `/api/v1/server/UniProxy/*` and `/api/v2/server/*`;
- panel authentication fields such as `token`, `node_type`, and `machine_id`;
- existing Xboard node configuration fields consumed by deployed panels;
- the legacy `xboard-node` executable alias during the migration window;
- `xbctl` and the legacy native/systemd `/etc/xboard-node` layout for existing installations;
- the in-container `/etc/xboard-node/config.yml` path until deployment compatibility is migrated explicitly.

Canonical TX-Node-facing identities are:

- node binary: `tx-node`;
- host Docker deployment directory: `/etc/txnode`;
- Docker image: `ghcr.io/paimoncai/tx-node`;
- management entry point: `deploy.sh` / `txnode`.

`xbctl` is intentionally **not** renamed to `txctl` yet. Its upgrade/service logic still models the legacy systemd installation, so presenting it as a new TX-Node CLI would be misleading and could pull binaries from the old upstream path.

## Go module identity

The Go module and TX-Node self-imports use:

```text
github.com/PaiMonCai/TX-Node
```

This source-identity change does not alter Xboard panel protocol compatibility.

## Kernel fork dependencies

`go.mod` currently contains replacements to `cedar2025` kernel forks. Those are runtime dependencies, not repository branding. Do not remove them until their deltas are audited and TX-Node is proven against official upstream versions or TX-Node-maintained forks.

## Compatibility window

Standalone releases publish the canonical `tx-node` binary while preserving `xboard-node` and `xbctl` artifacts where required for existing installations. Remove legacy names only in a separately announced breaking release.
