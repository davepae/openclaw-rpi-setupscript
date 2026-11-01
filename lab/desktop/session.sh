#!/bin/bash
# Inside dbus-run-session: X11 display, window manager, optional loopback VNC, then the node host
# in the foreground (the plugin verifies driver artifacts before the first capability declaration).
set -euo pipefail
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &
for _ in $(seq 1 50); do xdpyinfo -display :99 >/dev/null 2>&1 && break; sleep 0.2; done
xdpyinfo -display :99 >/dev/null || { echo "Xvfb did not start" >&2; exit 1; }
openbox &
if [[ "${ENABLE_VNC:-1}" == "1" ]]; then
  # Loopback inside the container only — for the Control UI Desktop panel via the node host.
  x11vnc -display :99 -localhost -forever -shared -quiet -nopw -rfbport 5900 &
fi

openclaw doctor --lint --only cua-computer/driver-artifacts || echo "WARN: CUA driver artifact check reported findings" >&2

if [[ -s "$HOME/.openclaw/join-url" ]]; then
  echo "Enrolling with the Gateway (single-use join URL)…"
  date -u +%FT%TZ >"$HOME/.openclaw/.enrolled"
  exec openclaw connect --target-file "$HOME/.openclaw/join-url" --display-name "${NODE_NAME:-lab-desktop}"
fi
[[ -s "$HOME/.openclaw/.enrolled" ]] || { echo "Not enrolled: recreate the container with a fresh OPENCLAW_JOIN_URL" >&2; exit 1; }
exec openclaw node run --display-name "${NODE_NAME:-lab-desktop}"
