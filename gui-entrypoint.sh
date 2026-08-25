#!/usr/bin/env bash
set -euo pipefail

export DISPLAY="${DISPLAY:-:99}"
Xvfb "$DISPLAY" -screen 0 "${AGENT_LAB_SCREEN:-1920x1080x24}" -ac +extension RANDR &
xvfb_pid=$!
trap 'kill "$xvfb_pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break; sleep 0.1; done
fluxbox >/tmp/fluxbox.log 2>&1 &
x11vnc -display "$DISPLAY" -forever -shared -nopw -rfbport 5900 >/tmp/x11vnc.log 2>&1 &
/usr/share/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 6080 >/tmp/novnc.log 2>&1 &
exec "$@"
