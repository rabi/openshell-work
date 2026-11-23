// Rewrite host keyring lookups in a models.json copy to the env vars the
// sandbox providers inject. Run by build.sh on pi-config/agent/models.json only;
// the host file keeps its !secret-tool entries.
import { readFileSync, writeFileSync } from "node:fs";

const path = process.argv[2];
const doc = JSON.parse(readFileSync(path, "utf8"));
const envName = (service) =>
	({ rhcorp: "QWEN_API_KEY", enmaas: "ENMAAS_API_KEY" })[service] ??
	`${service.toUpperCase().replace(/[^A-Z0-9]/g, "_")}_API_KEY`;

for (const provider of Object.values(doc.providers ?? {})) {
	const match = /^!secret-tool lookup service (\S+)$/.exec(provider.apiKey ?? "");
	if (!match) continue;
	provider.apiKey = `$${envName(match[1])}`;
}

writeFileSync(path, `${JSON.stringify(doc, null, "\t")}\n`);
