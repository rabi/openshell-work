#!/usr/bin/env bash
# Create the dev sandbox from the local image, then drop into pi.
# Workspace and pi config live inside the image; push host changes with:
#   openshell sandbox upload pi-dev ./workspace/<dir> /workspace/
# (upload cannot be combined with a trailing main command, hence --detach + exec)
set -eu
cd "$(dirname "$0")"

openshell sandbox create --name pi-dev --from localhost/pi-fedora:latest \
  --policy ./policy.yaml \
  --provider enmaas --provider rhcorp-qwen \
  --provider exa --provider context7 --provider jira-cloud --provider github-mcp \
  --detach

openshell sandbox exec -n pi-dev -- /usr/local/bin/pi
