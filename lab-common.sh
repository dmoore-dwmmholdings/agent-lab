#!/usr/bin/env bash
# Shared launcher logic for Agent Lab.
#
# Sourced by start-codex and start-claude, which must first set:
#   LAB_CLI        user-facing command name, e.g. codex-lab
#   LAB_DIR        absolute path to this repository
#   LAB_AGENT      display name, e.g. Codex
#   LAB_COMPOSE    base compose file name
#   LAB_PROJECT    compose project name for the headless image, e.g. codex-lab
#   LAB_HOME_VOL   agent home volume name, e.g. codex-lab-home
#   LAB_HOME_DIR   home directory inside the container, e.g. /home/codex
#   LAB_GUIDANCE   guidance destination inside the home volume
#   LAB_CMD        agent binary
#   LAB_ARGS       array of flags passed to the agent binary
#
# Note: macOS still ships bash 3.2, where expanding an empty array under `set
# -u` is a fatal error. Every array expansion below uses the
# ${arr[@]+"${arr[@]}"} guard for that reason.

set -euo pipefail

lab_credentials_enabled() {
  [[ "${AGENT_LAB_NO_CREDENTIALS:-0}" != 1 ]]
}

# Compose file arguments for the requested flavour: "headless" or "gui".
lab_compose_files() {
  local flavour="$1"
  printf '%s\n' -f "${LAB_DIR}/${LAB_COMPOSE}"
  if lab_credentials_enabled; then
    printf '%s\n' -f "${LAB_DIR}/compose.credentials.yaml"
  fi
  if [[ "$flavour" == gui ]]; then
    printf '%s\n' -f "${LAB_DIR}/compose.gui.yaml"
  fi
}

lab_project_name() {
  if [[ "$1" == gui ]]; then
    printf '%s-gui' "$LAB_PROJECT"
  else
    printf '%s' "$LAB_PROJECT"
  fi
}

# Compose derives the built image tag from the project name and the service
# name, so a distinct project name per flavour is what keeps the four possible
# images (codex/claude x headless/gui) from overwriting each other.
lab_image_name() {
  printf '%s-project' "$(lab_project_name "$1")"
}

lab_compose() {
  local flavour="$1"
  shift
  local files=()
  while IFS= read -r line; do files+=("$line"); done < <(lab_compose_files "$flavour")
  # PROJECT_DIR is only consulted for the bind mount, but compose validates it
  # for every subcommand, so `build` and `config` need a placeholder.
  PROJECT_DIR="${PROJECT_DIR:-$LAB_DIR}" \
    docker compose -p "$(lab_project_name "$flavour")" \
    ${files[@]+"${files[@]}"} "$@"
}

lab_build() {
  local flavour="$1"
  shift
  echo "[agent-lab] building the ${LAB_AGENT} ${flavour} image ($(lab_image_name "$flavour"))..." >&2
  lab_compose "$flavour" build "$@"
}

# The credential and guidance helpers below run plain `docker run` against an
# image that only compose knows how to build, so the image has to exist before
# they are called. Its absence is what made a fresh install fail: `codex-lab
# login` ran before anything had ever built the image, and Docker fell through
# to trying to pull `codex-lab-project` from Docker Hub.
lab_ensure_image() {
  local flavour="$1"
  if ! docker image inspect "$(lab_image_name "$flavour")" >/dev/null 2>&1; then
    lab_build "$flavour"
  fi
}

lab_credential_run_args() {
  lab_credentials_enabled || return 0
  printf '%s\n' \
    --volume agent-lab-github:/github \
    --volume agent-lab-gcloud:/gcloud \
    --env GH_CONFIG_DIR=/github/gh \
    --env GIT_CONFIG_GLOBAL=/github/gitconfig \
    --env CLOUDSDK_CONFIG=/gcloud \
    --env GOOGLE_APPLICATION_CREDENTIALS=/gcloud/application_default_credentials.json
}

# Run a one-off command against the agent home volume, with no project mounted.
lab_run_home_command() {
  lab_ensure_image headless
  local extra=()
  while IFS= read -r line; do extra+=("$line"); done < <(lab_credential_run_args)
  local tty_args=()
  if [[ -t 0 && -t 1 ]]; then
    tty_args=(-it)
  fi
  exec docker run --rm --init ${tty_args[@]+"${tty_args[@]}"} \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --pids-limit "${AGENT_LAB_PIDS_LIMIT:-4096}" \
    --tmpfs /tmp:rw,noexec,nosuid,size=1g \
    --volume "${LAB_HOME_VOL}:${LAB_HOME_DIR}" \
    ${extra[@]+"${extra[@]}"} \
    "$(lab_image_name headless)" "$@"
}

# Install the shipped authoring guidance into the agent's global memory file.
#
# Refreshes it when the shipped copy changes, but never clobbers a file the user
# edited by hand: a stamp of the last installed version distinguishes an
# untouched copy from a customised one.
lab_ensure_guidance() {
  lab_ensure_image headless
  docker run --rm --init \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --volume "${LAB_HOME_VOL}:${LAB_HOME_DIR}" \
    --env AGENT_LAB_GUIDANCE="$LAB_GUIDANCE" \
    --env AGENT_LAB_STAMP="${LAB_HOME_DIR}/.agent-lab/guidance.installed.md" \
    "$(lab_image_name headless)" bash -lc '
      set -eu
      shipped=/opt/agent-lab/guidance.md
      target="$AGENT_LAB_GUIDANCE"
      stamp="$AGENT_LAB_STAMP"
      mkdir -p "$(dirname "$target")" "$(dirname "$stamp")"
      if [ ! -e "$target" ]; then
        cp "$shipped" "$target"
        cp "$shipped" "$stamp"
      elif [ ! -e "$stamp" ]; then
        # Pre-existing install. Adopt an untouched copy so later refreshes work;
        # anything else is treated as user-owned from here on.
        if cmp -s "$shipped" "$target"; then
          cp "$shipped" "$stamp"
        else
          echo "[agent-lab] $target has local edits; leaving it alone." >&2
        fi
      elif cmp -s "$target" "$stamp"; then
        if ! cmp -s "$shipped" "$target"; then
          cp "$shipped" "$target"
          cp "$shipped" "$stamp"
          echo "[agent-lab] refreshed $target" >&2
        fi
      elif ! cmp -s "$shipped" "$target"; then
        echo "[agent-lab] $target has local edits; leaving it alone." >&2
      fi
    ' >/dev/null
}

lab_github() {
  local setup_git='gh auth setup-git --hostname github.com && (git config --global --unset-all url."https://github.com/".insteadOf || true) && git config --global --add url."https://github.com/".insteadOf "git@github.com:" && git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"'
  if ! lab_credentials_enabled; then
    echo "GitHub credentials are disabled by AGENT_LAB_NO_CREDENTIALS=1." >&2
    exit 64
  fi
  case "${1:-}" in
    login)
      shift
      lab_run_home_command bash -lc "GH_BROWSER=echo gh auth login --hostname github.com --git-protocol https --web && ${setup_git}"
      ;;
    setup-git)
      shift
      lab_run_home_command bash -lc "$setup_git"
      ;;
    identity)
      shift
      if [[ $# -ne 2 ]]; then
        echo "Usage: ${LAB_CLI} github identity 'Your Name' you@example.com" >&2
        exit 64
      fi
      # Positionals are passed to the inner shell on purpose; do not expand here.
      # shellcheck disable=SC2016
      lab_run_home_command sh -c 'git config --global user.name "$1" && git config --global user.email "$2"' sh "$1" "$2"
      ;;
    status|logout)
      local subcommand="$1"
      shift
      lab_run_home_command gh auth "$subcommand" "$@"
      ;;
    *)
      echo "Usage: ${LAB_CLI} github <login|setup-git|identity|status|logout>" >&2
      exit 64
      ;;
  esac
}

lab_gcloud() {
  if ! lab_credentials_enabled; then
    echo "Google Cloud credentials are disabled by AGENT_LAB_NO_CREDENTIALS=1." >&2
    exit 64
  fi
  case "${1:-}" in
    login)
      shift
      lab_run_home_command gcloud auth login --no-launch-browser "$@"
      ;;
    firestore-login|adc-login)
      shift
      lab_run_home_command gcloud auth application-default login --no-launch-browser "$@"
      ;;
    status)
      shift
      lab_run_home_command gcloud auth list "$@"
      ;;
    *)
      echo "Usage: ${LAB_CLI} gcloud <login|firestore-login|status>" >&2
      exit 64
      ;;
  esac
}

# Explicit rebuild. Nothing else refreshes an existing image, so without this a
# pulled Dockerfile change or a Framewatch version bump never takes effect.
lab_build_command() {
  local flavour=headless
  local pull=(--pull)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gui) flavour=gui ;;
      --no-pull) pull=() ;;
      *) echo "Usage: ${LAB_CLI} build [--gui] [--no-pull]" >&2; exit 64 ;;
    esac
    shift
  done
  lab_build "$flavour" ${pull[@]+"${pull[@]}"}
  echo "[agent-lab] rebuilt $(lab_image_name "$flavour")."
}

lab_compose_run() {
  local flavour="$1"
  shift
  local ports=()
  if [[ "$flavour" == gui ]]; then
    # `docker compose run` deliberately does not publish service ports unless
    # asked.  The desktop is reached through noVNC on 6080, so expose the
    # loopback-only mapping declared by compose.gui.yaml for GUI sessions.
    ports=(--service-ports)
  fi
  lab_compose "$flavour" run --rm ${ports[@]+"${ports[@]}"} project "$@" \
    node /usr/local/bin/agent-lab-entrypoint.mjs \
    "$LAB_CMD" ${LAB_ARGS[@]+"${LAB_ARGS[@]}"}
}

lab_launch() {
  local flavour="$1" project_dir="$2"
  if [[ ! -d "$project_dir" ]]; then
    echo "Not a directory: $project_dir" >&2
    exit 66
  fi
  PROJECT_DIR="$(cd "$project_dir" && pwd -P)"
  WORKSPACE_DIR="/workspace/$(basename "$PROJECT_DIR")"
  export PROJECT_DIR WORKSPACE_DIR
  if ! lab_credentials_enabled; then
    echo "[agent-lab] AGENT_LAB_NO_CREDENTIALS=1: GitHub and Google Cloud credentials are not mounted." >&2
  fi
  lab_ensure_image "$flavour"
  lab_ensure_guidance
  local prefix=()
  if [[ "$flavour" == gui ]]; then
    prefix=(/usr/local/bin/agent-lab-gui-entrypoint)
    echo "[agent-lab] desktop: http://localhost:6080/vnc.html" >&2
  fi
  lab_compose_run "$flavour" ${prefix[@]+"${prefix[@]}"}
}

lab_usage() {
  cat <<EOF
Usage: ${LAB_CLI} /absolute/path/to/project
       ${LAB_CLI} gui /absolute/path/to/project
       ${LAB_CLI} lume /absolute/path/to/project
       ${LAB_CLI} build [--gui] [--no-pull]
       ${LAB_CLI} github <login|setup-git|identity|status|logout>
       ${LAB_CLI} gcloud <login|firestore-login|status>

Environment:
       AGENT_LAB_NO_CREDENTIALS=1   do not mount shared GitHub/Google Cloud credentials
       AGENT_LAB_PIDS_LIMIT=<n>     process cap inside the container (default 4096)
EOF
}
