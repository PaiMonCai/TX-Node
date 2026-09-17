# TX-Node standalone maintenance policy

TX-Node is maintained as an independent project. It originated from Xboard-Node and keeps Xboard panel compatibility where that compatibility is part of the protocol surface, but TX-Node no longer treats upstream synchronization as its development model.

## Source of truth

- `PaiMonCai/TX-Node` is the source of truth for TX-Node development and releases.
- `main` is the product mainline.
- Releases are created from semantic `v*` tags only.
- Upstream repositories are references for fixes and ideas, not merge targets.

## Upstream changes

Do not periodically merge an upstream branch into TX-Node. When an upstream change is useful:

1. inspect the upstream diff;
2. confirm the same issue or feature applies to TX-Node;
3. port or cherry-pick the minimal change;
4. adapt it to TX-Node architecture and tests;
5. release it under the TX-Node version line.

This keeps TX-Node changes reviewable and avoids reintroducing upstream assumptions into audit, deployment, machine-health, and release code.

## Compatibility boundary

The following are compatibility surfaces and are not branding leftovers:

- Xboard panel API paths such as `/api/v1/server/UniProxy/*` and `/api/v2/server/*`;
- panel authentication fields (`token`, `node_type`, `machine_id`, etc.);
- existing Xboard node configuration fields consumed by deployed panels;
- the legacy `xboard-node` / `xbctl` executable names during the migration window;
- the in-container `/etc/xboard-node/config.yml` path until deploy compatibility has been migrated explicitly.

New TX-Node-facing names are canonical:

- node binary: `tx-node`;
- control utility: `txctl`;
- host deployment directory: `/etc/txnode`;
- Docker image: `ghcr.io/paimoncai/tx-node`;
- management command: `txnode`.

## Go module migration

The repository still uses `github.com/cedar2025/xboard-node` as its Go module/import identity at the start of the standalone migration. This is intentional for the first compatibility step: changing the module path requires an atomic rewrite of every internal import and a full test/build pass.

The target module identity is:

```text
github.com/PaiMonCai/TX-Node
```

It should be migrated in one dedicated commit rather than mixed with binary/runtime renaming.

## Kernel fork dependencies

`go.mod` currently replaces upstream sing-box and xray-core with `cedar2025` forks. These are runtime dependencies, not merely repository branding. They must not be removed until their deltas are understood and TX-Node is proven to work against either official upstream versions or TX-Node-maintained forks.

Treat these replacements as explicit compatibility debt and review them separately from the Go module rename.

## Release compatibility window

During the standalone migration, release builds publish both canonical and legacy binary filenames. Once deployment telemetry/documentation confirms the legacy names are no longer required, remove them in a separately announced breaking release.
