#!/usr/bin/env bash
# Create one dev sandbox per work area, each with its own tmux session.
# Usage: bash create-many.sh [name...]   (default: pi-openshift pi-openstack pi-llm)
set -eu
cd "$(dirname "$0")"

names=("$@")
if [ "${#names[@]}" -eq 0 ]; then
  names=(pi-openshift pi-openstack pi-llm)
fi

for name in "${names[@]}"; do
  if openshell sandbox get "$name" >/dev/null 2>&1; then
    echo "== $name: already exists, skipping"
    continue
  fi
  echo "== $name: creating"
  openshell sandbox create --name "$name" --from localhost/pi-fedora:latest \
    --policy ./policy.yaml \
    --provider enmaas --provider rhcorp-qwen \
    --provider exa --provider context7 --provider jira-cloud --provider github-mcp \
    --cpu 2 --memory 4Gi \
    --detach -- tmux new -A -s work
done

openshell sandbox list
echo
echo "connect:      openshell sandbox connect <name>"
echo "extra shells: ssh openshell-<name>.default   (then: tmux attach -t work)"
