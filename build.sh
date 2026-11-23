#!/usr/bin/env bash
# Copy only the config pi reads into the build context, then build.
# pi's user config root is <HOME>/.pi/agent (config.ts:626-635); HOME inside the
# sandbox is /workspace, so everything lands under pi-config/agent/.
set -eu
cd "$(dirname "$0")"

src="$HOME/.pi/agent"
dst="pi-config/agent"
rm -rf pi-config
mkdir -p "$dst"

for f in settings.json models.json models-store.json oauth.json trust.json AGENTS.md; do
  [ -f "$src/$f" ] && cp -a "$src/$f" "$dst/"
done

# Replace host keyring lookups with the env vars the sandbox providers inject.
# Host keeps its !secret-tool entries; only the baked copy is rewritten.
[ -f "$dst/models.json" ] && node ./transform-models.mjs "$dst/models.json"

# pi-sandbox is host-side only (it drives local podman); drop it for the image.
# pi-anthropic-vertex is unused in the sandbox (no Anthropic/Vertex provider
# in models.json); dropping saves install time and image size.
if [ -f "$dst/settings.json" ]; then
  node -e '
    const fs = require("node:fs");
    const p = process.argv[1];
    const s = JSON.parse(fs.readFileSync(p, "utf8"));
    s.packages = (s.packages ?? []).filter((pkg) => !/pi-sandbox|pi-anthropic-vertex/.test(pkg));
    fs.writeFileSync(p, JSON.stringify(s, null, "\t") + "\n");
  ' "$dst/settings.json"
fi

for d in skills extensions; do
  [ -d "$src/$d" ] && cp -a "$src/$d" "$dst/"
done

# sandbox-specific overrides win over host config (host mcp.json points at host paths)
# sandbox-specific overrides win over host config (host mcp.json points at host paths);
# render ${VAR} placeholders from .env first
while IFS= read -r -d '' f; do
  rel=${f#sandbox-overrides/}
  mkdir -p "pi-config/$(dirname "$rel")"
  render_to "pi-config/$rel" "$f"
done < <(find sandbox-overrides -type f -print0)

mkdir -p workspace
podman build --network=host --build-arg CACHEBUST="$(date +%s)" -t localhost/pi-fedora:latest .
