#!/usr/bin/env bash
# Phase 8 (Pi side) — enroll and lock down the lab nodes. Run with sudo on the Pi.
#   sudo pi/80-nodes.sh join        mint a single-use join URL (valid ~10 min) for the next node
#   sudo pi/80-nodes.sh status      list devices / nodes / pending approvals
#   sudo pi/80-nodes.sh approve ID  approve a pending node surface update (e.g. computer.act)
#   sudo pi/80-nodes.sh finish      re-apply approvals documents from the Pi, pin the lab agent,
#                                   enable computer use for the lab agent if the desktop node exists
source "$(dirname "$0")/../lib/common.sh"
require_root
oc() { as_user "$OC_USER" "openclaw $*"; }
cmd="${1:-status}"

case "$cmd" in
  join)
    warn "Admin-minted join codes approve the device AND its first declared command surface (incl. system.run)."
    warn "So set the node's local approvals document BEFORE redeeming the URL (lab scripts do this)."
    oc "devices join-code"
    echo
    echo "On the lab VM (as root):  lab/20-exec-node.sh      (paste the URL) for $LAB_EXEC_NODE_NAME"
    echo "                      or:  lab/30-desktop-node.sh   (paste the URL) for $LAB_DESKTOP_NODE_NAME"
    ;;
  status)
    oc "devices list"; oc "nodes status" || oc "nodes list" || true; oc "nodes pending"; oc "approvals pending" || true
    ;;
  approve)
    [[ -n "${2:-}" ]] || die "usage: $0 approve <request-id>   (ids from: $0 status)"
    oc "nodes approve '$2'"
    ;;
  finish)
    stage="$(user_home "$OC_USER")/.cache/openclaw-config"
    install -d -m 700 -o "$OC_USER" -g "$OC_USER" "$stage"
    for f in approvals-lab-exec.json5 approvals-lab-desktop.json5 computer.patch.json5; do
      install -m 600 -o "$OC_USER" -g "$OC_USER" "$BUNDLE_DIR/config/$f" "$stage/$f"
    done
    nodes_json="$(as_user "$OC_USER" "openclaw nodes status --json" 2>/dev/null || as_user "$OC_USER" "openclaw nodes list --json")"
    has() { grep -q "\"$1\"" <<<"$nodes_json"; }

    if has "$LAB_EXEC_NODE_NAME"; then
      log "$LAB_EXEC_NODE_NAME: approvals from the Pi (allowlist + ask on-miss + deny)"
      oc "approvals set --node '$LAB_EXEC_NODE_NAME' --file '$stage/approvals-lab-exec.json5'"
      oc "approvals get --node '$LAB_EXEC_NODE_NAME'"
    else warn "$LAB_EXEC_NODE_NAME not connected yet"; fi

    if has "$LAB_DESKTOP_NODE_NAME"; then
      log "$LAB_DESKTOP_NODE_NAME: approvals deny all shell"
      oc "approvals set --node '$LAB_DESKTOP_NODE_NAME' --file '$stage/approvals-lab-desktop.json5'"
      oc "approvals get --node '$LAB_DESKTOP_NODE_NAME'"
      log "Allowing the computer tool for the lab agent only"
      oc "config patch --file '$stage/computer.patch.json5'"
      # Do NOT enable cua-computer here: on the Gateway host that explicit enablement turns on control
      # of the Pi's own desktop (docs/nodes/computer-use.md, "Gateway desktop"). It is enabled
      # inside the desktop-node container instead.
      if [[ "$(as_user "$OC_USER" "openclaw config get plugins.entries.cua-computer.enabled" 2>/dev/null)" == "true" ]]; then
        warn "cua-computer is explicitly enabled on the Pi — disabling Gateway desktop control"
        oc "config unset plugins.entries.cua-computer.enabled"
      fi
      warn "If 'nodes pending' shows a computer.act surface update for $LAB_DESKTOP_NODE_NAME, approve it: $0 approve <id>"
    else warn "$LAB_DESKTOP_NODE_NAME not connected yet"; fi

    oc "config validate"
    oc "exec-policy show --agent lab --verbose" || true
    stamp 80-nodes
    ;;
  *) die "usage: $0 join|status|approve <id>|finish" ;;
esac
