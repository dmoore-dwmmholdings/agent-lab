#!/usr/bin/env bash
set -euo pipefail

export DISPLAY="${DISPLAY:-:99}"
display_number="${DISPLAY#:}"
display_number="${display_number%%.*}"

# Xvfb refuses to create /tmp/.X11-unix unless it is running as root, and the
# compose file mounts a fresh tmpfs over /tmp on every start, so whatever the
# image ships at that path is masked. Create the directory before the server
# starts, otherwise Xvfb reports
#   _XSERVTransmkdir: ERROR: euid != 0, directory /tmp/.X11-unix will not be created
# and the display comes up without a usable socket path.
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

Xvfb "$DISPLAY" -screen 0 "${AGENT_LAB_SCREEN:-1920x1080x24}" -ac +extension RANDR &
xvfb_pid=$!
trap 'kill "$xvfb_pid" 2>/dev/null || true' EXIT

# Wait for the socket first: xdpyinfo cannot succeed before it exists, and the
# agent must not start against a display that is not accepting clients yet.
for _ in $(seq 1 100); do
  [ -S "/tmp/.X11-unix/X${display_number}" ] && break
  sleep 0.1
done
for _ in $(seq 1 100); do xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break; sleep 0.1; done

fluxbox >/tmp/fluxbox.log 2>&1 &
x11vnc -display "$DISPLAY" -forever -shared -nopw -rfbport 5900 >/tmp/x11vnc.log 2>&1 &
/usr/share/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 6080 >/tmp/novnc.log 2>&1 &
exec "$@"
