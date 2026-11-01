#!/usr/bin/env bash
# Phase 4 — join the tailnet. Serve itself is turned on by OpenClaw (gateway.tailscale.mode: "serve").
# Also used on the lab VM.
source "$(dirname "$0")/../lib/common.sh"
require_root
OPERATOR="${1:-$OC_USER}"; TAG="${2:-$TS_TAG_PI}"

if ! command -v tailscale >/dev/null; then
  log "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

if ! tailscale status >/dev/null 2>&1; then
  log "Bring the node up as ${TAG:-untagged} — open the printed URL to authenticate"
  # Tags must already exist in your tailnet policy's tagOwners (config/tailnet-policy.hujson).
  tailscale up --ssh=false ${TAG:+--advertise-tags="$TAG"}
fi

# Let the OpenClaw Gateway (running as $OPERATOR) configure Serve without root — OpenClaw's own
# Tailscale docs (2026.10.8, docs/gateway/tailscale.md) recommend exactly this.
tailscale set --operator="$OPERATOR"
ok "tailscale operator = $OPERATOR"

name="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
ip4="$(tailscale ip -4 | head -1)"
ok "MagicDNS name: $name   tailnet IP: $ip4"
echo "  -> put PI_TAILNET_NAME=\"$name\" and PI_TAILNET_IP=\"$ip4\" in config/settings.env (Pi only)"
warn "Now restrict this machine in your tailnet policy (see RUNBOOK 'Tailnet policy')."

# Re-apply egress so MagicDNS (100.100.100.100) is allowed if Tailscale took over DNS.
systemctl is-enabled openclaw-egress.service >/dev/null 2>&1 && systemctl restart openclaw-egress.service || true
stamp "40-tailscale"
