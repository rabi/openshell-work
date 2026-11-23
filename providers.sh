#!/usr/bin/env bash
# Import the sandbox profiles and create/refresh the provider instances.
# Run once, and again whenever a credential is rotated.
set -eu
cd "$(dirname "$0")"
# shellcheck disable=SC1091
. ./common.sh
load_env

import_profile() {
  local file=$1 id=$2 rendered
  rendered="$(mktemp).yaml"
  render_to "$rendered" "$file"
  openshell profile lint -f "$rendered"
  if openshell profile describe "$id" >/dev/null 2>&1; then
    openshell profile export "$id" > "/tmp/${id}-current.yaml"
    # keep the server's resource_version, take everything else from the file
    { grep -E '^(id|resource_version):' "/tmp/${id}-current.yaml"; grep -vE '^(id|resource_version|source|scope):' "$rendered"; } \
      > "/tmp/${id}-update.yaml"
    openshell provider profile update -f "/tmp/${id}-update.yaml" "$id"
  else
    openshell provider profile import -f "$rendered"
  fi
  rm -f "$rendered"
}

import_profile profiles/exa.yaml exa
import_profile profiles/context7.yaml context7
import_profile profiles/jira-cloud.yaml jira-cloud
import_profile profiles/github-mcp.yaml github-mcp
import_profile profiles/enmaas.yaml enmaas
import_profile profiles/rhcorp-qwen.yaml rhcorp-qwen

create_provider() {
  local name=$1 type=$2 key=$3
  if openshell provider get "$name" >/dev/null 2>&1; then
    openshell provider update "$name" --credential "$key"
  else
    openshell provider create --name "$name" --type "$type" --credential "$key"
  fi
}

export EXA_API_KEY="${EXA_API_KEY:-$(secret-tool lookup service exa)}"
export CONTEXT7_API_KEY="${CONTEXT7_API_KEY:-$(secret-tool lookup service context7)}"
export JIRA_API_TOKEN="${JIRA_API_TOKEN:-$(secret-tool lookup service jira)}"
export GITHUB_TOKEN="${GITHUB_TOKEN:-$(secret-tool lookup service github)}"
export ENMAAS_API_KEY="${ENMAAS_API_KEY:-$(secret-tool lookup service enmaas)}"
export QWEN_API_KEY="${QWEN_API_KEY:-$(secret-tool lookup service rhcorp)}"

create_provider exa exa EXA_API_KEY
create_provider context7 context7 CONTEXT7_API_KEY
create_provider jira-cloud jira-cloud JIRA_API_TOKEN
create_provider github-mcp github-mcp GITHUB_TOKEN
create_provider enmaas enmaas ENMAAS_API_KEY
create_provider rhcorp-qwen rhcorp-qwen QWEN_API_KEY
