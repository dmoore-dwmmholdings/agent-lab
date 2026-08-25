#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd -P)"
bin_dir="${HOME}/.local/bin"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker Desktop is required. Install and start it, then run this again." >&2
  exit 1
fi

for volume in codex-lab-home claude-lab-home agent-lab-github agent-lab-gcloud; do
  docker volume create "$volume" >/dev/null
done

mkdir -p "$bin_dir"
ln -sfn "$repo_dir/start-codex" "$bin_dir/codex-lab"
ln -sfn "$repo_dir/start-claude" "$bin_dir/claude-lab"
ln -sfn "$repo_dir/lume-lab" "$bin_dir/lume-lab"

echo "Agent Lab installed. Ensure ${bin_dir} is on your PATH."
echo "Then run: codex-lab login && codex-lab github login && codex-lab gcloud login"
