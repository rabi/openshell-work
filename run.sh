#!/usr/bin/env bash
# Run pi on any local repo checkout in an OpenShell sandbox, as separate steps:
#
#   run.sh build                          rebuild localhost/pi-fedora:latest
#                                         (runs ./build.sh: stages host pi config,
#                                         applies sandbox transforms, podman build)
#   run.sh up [dir] [--exec]              require the image, create sandbox
#                                         (repo uploaded via --upload), then
#                                         start pi as the canonical main
#                                         process in the repo folder: detach
#                                         with Ctrl-P Ctrl-Q and reattach via
#                                         `openshell sandbox connect <name>`;
#                                         exit pi and run `down` (it restarts
#                                         a stopped sandbox, workspace kept).
#                                         --exec uses the one-shot exec model
#                                         instead (session dies on disconnect)
#   run.sh down [dir] [--keep]            bring back sandbox changes: committed
#                                         work via git bundle + ff-merge,
#                                         uncommitted files via sandbox git
#                                         status; then delete the sandbox
#                                         (--keep leaves it running)
#   run.sh run [dir] [pi args]            up without connect, exec pi with args
#                                         (e.g. --print), then down
#   run.sh status                         show recorded sandboxes
#
# [dir] defaults to the current directory.
#
# Upload sends the whole dir; the CLI applies .gitignore filtering itself (full
# tree outside a git work tree) including .git (so commits work in the sandbox);
# git identity is copied from the repo's effective config and the repo is marked
# a safe.directory in the sandbox. Down pulls sandbox-side
# status changes (paths that exist only in the sandbox are included) and any
# commits made there (bundle -> fetch -> ff-merge; on conflict the bundle is
# kept next to the state file). Host edits made while the sandbox ran may be
# overwritten. State: ./.run-state/<repo>.env
set -eu
start_dir=$(readlink -f "$PWD")
cd "$(dirname "$0")"
# shellcheck disable=SC1091
. ./common.sh

image=localhost/pi-fedora:latest
state_dir=.run-state
providers=(enmaas rhcorp-qwen exa context7 jira-cloud github-mcp)

usage() { sed -n "2,33p" "$0" | sed 's/^# \{0,1\}//'; exit 2; }
state_file() { echo "$state_dir/$(basename "$1").env"; }

ensure_ssh_config() {
  local ssh_host="openshell-${sandbox}.default"
  if ! grep -qx "Host ${ssh_host}" "$HOME/.ssh/config" 2>/dev/null; then
    mkdir -p "$HOME/.ssh"
    echo "== adding ${ssh_host} to ~/.ssh/config"
    openshell sandbox ssh-config "$sandbox" >> "$HOME/.ssh/config"
  fi
}

cmd_up() {
  local repo=$1 connect=${2:-1} main=${3:-0} sandbox remote archive staging p
  staging=$(mktemp -d)
  local args=()
  for p in "${providers[@]}"; do args+=(--provider "$p"); done
  if ! podman image exists "$image"; then
    echo "image $image missing; run: bash $0 build" >&2
    exit 1
  fi
  sandbox="pi-run-$(date +%s | tail -c 5)$RANDOM" # max name length is 19
  remote="/workspace/$(basename "$repo")"
  echo "== creating sandbox $sandbox"
  local policy_rendered="$(mktemp).yaml"
  render_to "$policy_rendered" ./policy.yaml
  local create_args=(--name "$sandbox" --from "$image" --policy "$policy_rendered" "${args[@]}"
    --label "repo=$(basename "$repo")"
    --annotation "openshell-work.repo-path=$repo")
  if [ "$main" = 1 ]; then
    # docs model: canonical main process waits for the upload, then becomes pi;
    # reattachable with `openshell sandbox connect` after Ctrl-P Ctrl-Q
    openshell sandbox create "${create_args[@]}" --tty --detach -- \
      sh -c "while [ ! -e /workspace/.pi-ready ]; do sleep 1; done; cd '$remote' && exec /usr/local/bin/pi" >/dev/null
  else
    openshell sandbox create "${create_args[@]}" --detach >/dev/null
  fi

  echo "== uploading tree + .git as one tar"
  archive="$staging/repo.tar.gz"
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    {
      git -C "$repo" ls-files -z --cached --others --exclude-standard |
        while IFS= read -rd '' f; do { [ -f "$repo/$f" ] || [ -L "$repo/$f" ]; } && printf '%s\0' "$f"; done
      [ -d "$repo/.git" ] && printf '.git\0'
    } > "$staging/list.z"
  else
    find "$repo" -mindepth 1 \( -type f -o -type l \) -printf '%P\0' > "$staging/list.z"
  fi
  [ -s "$staging/list.z" ] || { echo "nothing to upload" >&2; exit 1; }
  tar -C "$repo" --null -czf "$archive" --verbatim-files -T "$staging/list.z"
  openshell sandbox upload --no-git-ignore "$sandbox" "$archive" "$(dirname "$remote")/"
  openshell sandbox exec -n "$sandbox" -- \
    sh -c "mkdir -p '$remote' && tar -xzf '/workspace/$(basename "$archive")' -C '$remote' && rm -f '/workspace/$(basename "$archive")'"
  rm -rf "$staging"

  if [ -d "$repo/.git" ]; then
    local name email
    name=$(git -C "$repo" config user.name || true)
    email=$(git -C "$repo" config user.email || true)
    [ -n "$name" ] && openshell sandbox exec -n "$sandbox" -- \
      git -C "$remote" config user.name "$name" || true
    [ -n "$email" ] && openshell sandbox exec -n "$sandbox" -- \
      git -C "$remote" config user.email "$email" || true
    openshell sandbox exec -n "$sandbox" -- \
      git config --global --add safe.directory "$remote"
  else
    echo "warn: no .git directory on host; git ops in the sandbox will not work" >&2
  fi

  mkdir -p "$state_dir"
  printf 'repo=%q\nsandbox=%q\nremote=%q\ngit=%q\nhead=%q\n' \
    "$repo" "$sandbox" "$remote" \
    "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null || echo 0)" \
    "$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo)" \
    > "$(state_file "$repo")"
  if [ "$connect" = 1 ]; then
    if [ "$main" = 1 ]; then
      openshell sandbox exec -n "$sandbox" -- touch /workspace/.pi-ready
      echo "== pi as main process in $remote (detach: Ctrl-P Ctrl-Q; reattach: openshell sandbox connect $sandbox)"
      exec openshell sandbox connect "$sandbox"
    fi
    echo "== pi (in $remote)"
    exec openshell sandbox exec -n "$sandbox" --workdir "$remote" -- /usr/local/bin/pi
  fi
}

cmd_down() {
  local repo=$1 keep=${2:-0} staging n sb_head range
  [ -f "$(state_file "$repo")" ] || { echo "no sandbox recorded for $repo (run up first)" >&2; exit 1; }
  . "$(state_file "$repo")"
  openshell sandbox get "$sandbox" >/dev/null || { echo "sandbox $sandbox gone" >&2; exit 1; }
  # pi-as-main-process: /quit exits cleanly -> Completed, but the container may
  # still be running (start then fails with "already running generation").
  # Probe exec; on failure restart, falling back to stop+start if needed.
  if ! openshell sandbox exec -n "$sandbox" -- true 2>/dev/null; then
    echo "== sandbox not accepting exec; restarting (workspace preserved)"
    openshell sandbox start "$sandbox" 2>/dev/null || {
      openshell sandbox stop "$sandbox"
      openshell sandbox start "$sandbox"
    }
  fi

  staging="$(mktemp -d)"
  if [ "$git" != 0 ]; then
    # commits made in the sandbox come back as a git bundle (fetched + ff-merged)
    sb_head=$(openshell sandbox exec -n "$sandbox" -- git -C "$remote" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$sb_head" ] && [ "$sb_head" != "$head" ]; then
      echo "== sandbox has commits; fetching bundle"
      local range=$([ -n "$head" ] && echo "$head..HEAD" || echo HEAD)
      openshell sandbox exec -n "$sandbox" -- \
        git -C "$remote" bundle create /workspace/.out.bundle "$range" >/dev/null
      openshell sandbox download "$sandbox" /workspace/.out.bundle "$staging/out.bundle" >/dev/null
      openshell sandbox exec -n "$sandbox" -- rm -f /workspace/.out.bundle
      if git -C "$repo" fetch -q "$staging/out.bundle" HEAD && git -C "$repo" merge -q --ff-only FETCH_HEAD; then
        echo "== merged sandbox commits"
      else
        cp "$staging/out.bundle" "$(state_file "$repo").bundle"
        echo "warn: ff-merge failed (host commits/dirty tree); bundle kept at $(state_file "$repo").bundle" >&2
      fi
    fi
    # uncommitted sandbox changes: sandbox-side status, tar'd sandbox-side
    openshell sandbox exec -n "$sandbox" -- \
      git -C "$remote" status --porcelain=v1 -z --untracked-files=all > "$staging/status.z"
    n=$(tr -d '\0' < "$staging/status.z" | wc -l)
    if [ "$n" -gt 0 ]; then
      echo "== downloading $n sandbox-side changed files into $repo"
      cut -z -s -c4- "$staging/status.z" |
        openshell sandbox exec -n "$sandbox" -- \
          sh -c "cd '$remote' && tar --null --ignore-failed-read -czf /workspace/.out.tar.gz -T -"
      openshell sandbox download "$sandbox" /workspace/.out.tar.gz "$staging/out.tar.gz" >/dev/null
      openshell sandbox exec -n "$sandbox" -- rm -f /workspace/.out.tar.gz
      tar -xzf "$staging/out.tar.gz" -C "$repo"
    else
      echo "== no uncommitted sandbox changes"
    fi
  else
    echo "== not a git repo, downloading full tree"
    openshell sandbox download "$sandbox" "$remote" "$staging" >/dev/null
    cp -a "$staging/$(basename "$remote")/." "$repo/"
  fi
  rm -rf "$staging"

  if [ "$keep" = 1 ]; then
    echo "== sandbox $sandbox kept running"
  else
    echo "== deleting sandbox $sandbox"
    openshell sandbox delete "$sandbox" || true
    rm -f "$(state_file "$repo")"
  fi
}

cmd_run() {
  local repo=$1 keep=${2:-0}
  shift 2
  cmd_up "$repo" 0
  . "$(state_file "$repo")"
  if [ $# -gt 0 ]; then
    openshell sandbox exec -n "$sandbox" -- sh -c "cd '$remote' && /usr/local/bin/pi $*"
  else
    openshell sandbox exec -n "$sandbox" --tty -- sh -c "cd '$remote' && /usr/local/bin/pi"
  fi
  cmd_down "$repo" "$keep"
}

cmd_status() {
  local f
  for f in "$state_dir"/*.env; do
    [ -e "$f" ] || continue
    ( . "$f"; printf '%-30s %s\n' "$(basename "$repo")" "$sandbox" )
  done
}

action="${1:-}"; shift || true
keep=0; main=1; args=()
for a in "$@"; do
  case "$a" in
    --keep) keep=1 ;;
    --exec) main=0 ;;
    *) args+=("$a") ;;
  esac
done
if [ ${#args[@]} -gt 0 ]; then dir=$(readlink -f "${args[0]}"); else dir=$start_dir; fi
case "$action" in
  build) ./build.sh ;;
  up)     cmd_up "$dir" 1 "$main" ;;
  down)   cmd_down "$dir" "$keep" ;;
  run)    set -- "$dir" "$keep" "${args[@]:1}"; cmd_run "$@" ;;
  status) cmd_status ;;
  *)      usage ;;
esac
