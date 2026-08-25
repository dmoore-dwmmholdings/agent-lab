#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd -P)"
bin_dir="${HOME}/.local/bin"
prebuild=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) prebuild=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./install.sh [--build]

  --build   build both agent images now instead of on first use
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 64
      ;;
  esac
  shift
done

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker Desktop is required. Install and start it, then run this again." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but not running. Start Docker Desktop, then run this again." >&2
  exit 1
fi

for volume in codex-lab-home claude-lab-home agent-lab-github agent-lab-gcloud; do
  docker volume create "$volume" >/dev/null
done

mkdir -p "$bin_dir"
ln -sfn "$repo_dir/start-codex" "$bin_dir/codex-lab"
ln -sfn "$repo_dir/start-claude" "$bin_dir/claude-lab"
ln -sfn "$repo_dir/lume-lab" "$bin_dir/lume-lab"

if [[ "$prebuild" == 1 ]]; then
  "$repo_dir/start-codex" build
  "$repo_dir/start-claude" build
else
  echo "Images are built automatically the first time you use each lab."
fi

echo
echo "Agent Lab installed. Ensure ${bin_dir} is on your PATH."
echo "Then run: codex-lab login && codex-lab github login && codex-lab gcloud login"
