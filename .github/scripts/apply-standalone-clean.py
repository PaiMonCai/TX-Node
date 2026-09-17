from pathlib import Path
import re

OLD = "github.com/cedar2025/xboard-node"
NEW = "github.com/PaiMonCai/TX-Node"


def require_replace(text: str, old: str, new: str, label: str, count: int = 1) -> str:
    if old not in text:
        raise SystemExit(f"missing expected text for {label}: {old!r}")
    return text.replace(old, new, count)

# 1) Go module identity + all self imports.
go_mod = Path("go.mod")
text = go_mod.read_text(encoding="utf-8")
text = require_replace(text, f"module {OLD}", f"module {NEW}", "go.mod module")
go_mod.write_text(text, encoding="utf-8")

for root in (Path("cmd"), Path("internal")):
    for path in root.rglob("*.go"):
        text = path.read_text(encoding="utf-8")
        if OLD + "/" in text:
            path.write_text(text.replace(OLD + "/", NEW + "/"), encoding="utf-8")

# User-visible node identity.
main_go = Path("cmd/xboard-node/main.go")
text = main_go.read_text(encoding="utf-8")
text = require_replace(
    text,
    'fmt.Printf("xboard-node %s (built %s)\\n", version, buildTime)',
    'fmt.Printf("tx-node %s (built %s)\\n", version, buildTime)',
    "version output",
)
main_go.write_text(text, encoding="utf-8")

# 2) Canonical build artifact is tx-node. xbctl remains intentionally legacy.
make = Path("Makefile")
text = make.read_text(encoding="utf-8")
text = text.replace("-o xboard-node ./cmd/xboard-node", "-o tx-node ./cmd/xboard-node", 1)
if "\tln -sf tx-node xboard-node\n" not in text:
    needle = "-o tx-node ./cmd/xboard-node\n"
    if needle not in text:
        raise SystemExit("unable to locate main tx-node build command")
    text = text.replace(needle, needle + "\tln -sf tx-node xboard-node\n", 1)

for arch in ("amd64", "arm64"):
    old = f"-o xboard-node-linux-{arch} ./cmd/xboard-node"
    new = f"-o tx-node-linux-{arch} ./cmd/xboard-node"
    if old in text:
        text = text.replace(old, new, 1)
    copy_line = f"\tcp tx-node-linux-{arch} xboard-node-linux-{arch}\n"
    if copy_line not in text:
        needle = new + "\n"
        if needle not in text:
            raise SystemExit(f"unable to locate linux {arch} build command")
        text = text.replace(needle, needle + copy_line, 1)

# Keep native legacy config layout for compatibility, but install tx-node canonically.
text = text.replace(
    "\tsudo cp xboard-node /usr/local/bin/xboard-node\n",
    "\tsudo cp tx-node /usr/local/bin/tx-node\n\tsudo ln -sf /usr/local/bin/tx-node /usr/local/bin/xboard-node\n",
    1,
)
text = re.sub(
    r"^\trm -f .*xboard-node.*xbctl.*$",
    "\trm -f tx-node xboard-node xbctl tx-node-linux-* xboard-node-linux-* xbctl-linux-*",
    text,
    count=1,
    flags=re.M,
)
text = text.replace("docker build -t xboard-node:", "docker build -t tx-node:")
make.write_text(text, encoding="utf-8")

# 3) Docker runtime identity. Keep /etc/xboard-node inside the container as a
# compatibility mount path; deploy.sh already presents /etc/txnode host-side.
dockerfile = Path("Dockerfile")
text = dockerfile.read_text(encoding="utf-8")
text = text.replace("-o xboard-node ./cmd/xboard-node", "-o tx-node ./cmd/xboard-node", 1)
text = text.replace(
    "COPY --from=builder /build/xboard-node /usr/local/bin/xboard-node",
    "COPY --from=builder /build/tx-node /usr/local/bin/tx-node",
    1,
)
if "ln -s /usr/local/bin/tx-node /usr/local/bin/xboard-node" not in text:
    text = text.replace(
        "RUN mkdir -p /etc/xboard-node",
        "RUN ln -s /usr/local/bin/tx-node /usr/local/bin/xboard-node \\\n    && mkdir -p /etc/xboard-node",
        1,
    )
text = text.replace('ENTRYPOINT ["xboard-node"]', 'ENTRYPOINT ["tx-node"]', 1)
dockerfile.write_text(text, encoding="utf-8")

# 4) CI: publish canonical tx-node plus legacy aliases; Release only from v* tags.
ci = Path(".github/workflows/ci.yml")
text = ci.read_text(encoding="utf-8")
text = text.replace(
    "if: startsWith(github.ref, 'refs/tags/') || github.ref == 'refs/heads/main'",
    "if: startsWith(github.ref, 'refs/tags/')",
)
text = text.replace(
    "tag_name: ${{ startsWith(github.ref, 'refs/tags/') && github.ref_name || 'main' }}",
    "tag_name: ${{ github.ref_name }}",
)

old_block = """      - name: Upload xboard-node artifact
        uses: actions/upload-artifact@v4
        with:
          name: xboard-node-${{ matrix.goos }}-${{ matrix.goarch }}
          path: xboard-node-${{ matrix.goos }}-${{ matrix.goarch }}
"""
new_block = """      - name: Upload tx-node artifact
        uses: actions/upload-artifact@v4
        with:
          name: tx-node-${{ matrix.goos }}-${{ matrix.goarch }}
          path: tx-node-${{ matrix.goos }}-${{ matrix.goarch }}

      - name: Upload legacy xboard-node artifact
        uses: actions/upload-artifact@v4
        with:
          name: xboard-node-${{ matrix.goos }}-${{ matrix.goarch }}
          path: xboard-node-${{ matrix.goos }}-${{ matrix.goarch }}
"""
if old_block in text:
    text = text.replace(old_block, new_block, 1)
elif "Upload tx-node artifact" not in text:
    raise SystemExit("expected xboard-node artifact block not found")

if "dist/tx-node-linux-amd64" not in text:
    text = text.replace(
        "          files: |\n            dist/xboard-node-linux-amd64\n",
        "          files: |\n            dist/tx-node-linux-amd64\n            dist/tx-node-linux-arm64\n            dist/xboard-node-linux-amd64\n",
        1,
    )
text = text.replace("          make_latest: ${{ startsWith(github.ref, 'refs/tags/') }}", "          make_latest: true")
ci.write_text(text, encoding="utf-8")

# 5) Standalone maintenance policy.
standalone = """# TX-Node standalone maintenance policy

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
"""
Path("docs/standalone.md").write_text(standalone, encoding="utf-8")

# 6) README identity. Preserve the deployment/reference body; only replace the
# introductory identity section and the old upstream-centric final section.
readme_path = Path("README.md")
readme = readme_path.read_text(encoding="utf-8")
if not readme.startswith("# TX-Node"):
    raise SystemExit("README does not start with # TX-Node")
first_h2 = readme.find("\n## ")
if first_h2 == -1:
    raise SystemExit("README first H2 not found")
intro = """# TX-Node

TX-Node 是独立维护的 **Xboard 兼容节点运行时**，支持 `sing-box` / `xray-core` 双内核，并在节点运行、machine 自愈、访问审计、部署运维和发布流程上持续独立演进。

项目起源于 [cedar2025/Xboard-Node](https://github.com/cedar2025/Xboard-Node)。TX-Node 保留 Xboard 面板 API、认证字段和现有节点配置的协议兼容，但不再以周期性同步上游作为开发模式；上游后续修复会按需审查并选择性移植。独立维护策略见 [`docs/standalone.md`](docs/standalone.md)。
"""
readme = intro + readme[first_h2:]
legacy_heading = "## 原版用法（不变的部分）"
pos = readme.find(legacy_heading)
compat = """## Xboard 兼容与项目来源

TX-Node 保留 Xboard 面板协议及兼容配置字段。`xbctl` 与原生 `/etc/xboard-node` systemd 布局仅作为 legacy compatibility 保留；新的 Docker 运维入口是 `deploy.sh` / `txnode`。

项目历史来源于 [cedar2025/Xboard-Node](https://github.com/cedar2025/Xboard-Node)。后续 TX-Node 版本独立维护和发布；上游修复仅按需审查、移植，不再整分支同步。详见 [`docs/standalone.md`](docs/standalone.md)。
"""
if pos != -1:
    readme = readme[:pos] + compat
elif "## Xboard 兼容与项目来源" not in readme:
    readme = readme.rstrip() + "\n\n" + compat
readme_path.write_text(readme, encoding="utf-8")

# Guardrails: do not accidentally leave the old self-module identity or invent txctl.
for root in (Path("go.mod"), Path("cmd"), Path("internal")):
    paths = [root] if root.is_file() else list(root.rglob("*.go"))
    for path in paths:
        if OLD + "/" in path.read_text(encoding="utf-8"):
            raise SystemExit(f"old self import remains in {path}")

for path in (Path("Makefile"), Path(".github/workflows/ci.yml"), Path("docs/standalone.md")):
    if "txctl" in path.read_text(encoding="utf-8"):
        raise SystemExit(f"txctl must not be introduced yet: {path}")

print("standalone migration edits prepared")
