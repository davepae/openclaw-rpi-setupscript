#!/bin/bash
# Container start: lock down local exec approvals, enable the Linux CUA fulfiller on THIS node,
# then start a private D-Bus session that runs the X server and the node host.
set -euo pipefail
export PATH=/opt/openclaw/bin:$PATH

# 1. No shell, ever: security "deny" (computer still works; --commands would disable it).
openclaw approvals set --file /opt/approvals.json5 >/dev/null
openclaw approvals get | sed -n '1,12p'

# 2. Enable the experimental Linux fulfiller here (never on the Gateway host).
openclaw plugins enable cua-computer

# 3. Hand a first-run join URL to the session via a private file (consumed by --target-file).
if [[ -n "${OPENCLAW_JOIN_URL:-}" && ! -s "$HOME/.openclaw/.enrolled" ]]; then
  umask 077; printf '%s\n' "$OPENCLAW_JOIN_URL" >"$HOME/.openclaw/join-url"
fi
unset OPENCLAW_JOIN_URL

exec dbus-run-session -- /opt/session.sh
