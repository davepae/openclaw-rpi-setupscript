#!/usr/bin/env bash
# Runs the Pi phases in order, skipping ones already completed (.state/<phase>).
# Usage: sudo ./install-pi.sh [--from NN]     e.g. --from 60 to redo images onward
source "$(dirname "$0")/lib/common.sh"
require_root
from="00"; [[ "${1:-}" == "--from" ]] && from="$2"
phases=(00-preflight 10-base 20-egress 30-docker 40-tailscale 50-openclaw 60-images 70-configure 90-timers 99-verify)
for p in "${phases[@]}"; do
  n="${p%%-*}"; (( 10#$n < 10#$from )) && continue
  st="$BUNDLE_DIR/.state/$p"; [[ "$p" == 30-docker ]] && st="$BUNDLE_DIR/.state/30-docker-$OC_USER"
  if [[ -e "$st" && "$n" != "$from" ]]; then ok "skip $p (done)"; continue; fi
  log "=== $p ==="
  "$BUNDLE_DIR/pi/$p.sh"
  if [[ "$p" == 10-base ]]; then
    warn "Reboot recommended after the base phase if packages or the kernel changed: sudo reboot, then rerun ./install-pi.sh"
    confirm "Continue without rebooting?" || exit 0
  fi
  if [[ "$p" == 40-tailscale ]] && ! grep -q '^PI_TAILNET_NAME="[^"]' "$BUNDLE_DIR/config/settings.env"; then
    warn "Fill PI_TAILNET_NAME / PI_TAILNET_IP in config/settings.env, set the tailnet policy (RUNBOOK phase 4), then rerun."
    exit 0
  fi
done
log "Pi phases done. Lab: copy this bundle to the lab VM and follow RUNBOOK phase 8."
