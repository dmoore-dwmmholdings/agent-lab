#!/usr/bin/env bash
set -euo pipefail

export DISPLAY="${DISPLAY:-:99}"
install -d -m 1777 /tmp/.X11-unix
Xvfb "$DISPLAY" -screen 0 "${AGENT_LAB_SCREEN:-1920x1080x24}" -ac +extension RANDR &
xvfb_pid=$!
trap 'kill "$xvfb_pid" 2>/dev/null || true' EXIT

# xdpyinfo comes from x11-utils. Without it this loop silently fails every
# iteration and the desktop starts against a display that may not exist yet.
for _ in $(seq 1 100); do xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break; sleep 0.1; done
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  echo "[agent-lab] X display $DISPLAY did not come up" >&2
  exit 1
fi
fluxbox >/tmp/fluxbox.log 2>&1 &
x11vnc -display "$DISPLAY" -forever -shared -nopw -rfbport 5900 >/tmp/x11vnc.log 2>&1 &
/usr/share/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 6080 >/tmp/novnc.log 2>&1 &
# The X stack above only needs to be started once, by whoever we already are.
# Drop to the unprivileged agent user only if we are actually root: `runuser`
# refuses to run as a non-root user, and under `cap_drop: ALL` even root cannot
# setgid, so an unconditional call fails in every configuration this repo ships.
if [ "$(id -u)" -eq 0 ]; then
  exec runuser -u "${AGENT_LAB_USER:?AGENT_LAB_USER is required}" --preserve-environment -- "$@"
fi
exec "$@"
