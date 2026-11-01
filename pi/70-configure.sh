#!/usr/bin/env bash
# Phase 7 — apply the design's openclaw.json, the Gateway host approvals document, and the
# drift policy; then run the built-in gates. Run with sudo. Safe to rerun.
source "$(dirname "$0")/../lib/common.sh"
require_root
home="$(user_home "$OC_USER")"
stage="$home/.cache/openclaw-config"; install -d -m 700 -o "$OC_USER" -g "$OC_USER" "$stage"

export OC_HOME="$home"
render "$BUNDLE_DIR/config/openclaw.patch.json5" >"$stage/openclaw.patch.json5"
for f in approvals-gateway.json5 elevated.patch.json5 computer.patch.json5 policy.jsonc; do
  cp "$BUNDLE_DIR/config/$f" "$stage/$f"
done
chown -R "$OC_USER:$OC_USER" "$stage"; chmod 600 "$stage"/*

oc() { as_user "$OC_USER" "openclaw $*"; }

log "Backing up current config"
oc "backup create --only-config --verify" || warn "config backup failed (continuing)"

log "Config patch (dry run, then apply)"
oc "config patch --file '$stage/openclaw.patch.json5' --dry-run"
oc "config patch --file '$stage/openclaw.patch.json5'"
oc "config validate"

if [[ "${ENABLE_ELEVATED:-0}" == "1" ]]; then
  warn "ENABLE_ELEVATED=1: applying tools.elevated.allowFrom.webchat=[\"*\"] (security audit: CRITICAL by design; see RUNBOOK)"
  oc "config patch --file '$stage/elevated.patch.json5'"
fi

log "Restarting the Gateway"
as_user "$OC_USER" "systemctl --user restart openclaw-gateway.service"
for _ in $(seq 1 30); do oc "gateway status --require-rpc" >/dev/null 2>&1 && break; sleep 2; done
oc "gateway status --deep --require-rpc"

log "Gateway host approvals: allowlist + ask always + deny on no answer"
oc "approvals set --gateway --file '$stage/approvals-gateway.json5'"
oc "approvals get --gateway"

log "Drift policy (bundled Policy plugin)"
install -m 600 -o "$OC_USER" -g "$OC_USER" "$stage/policy.jsonc" "$home/workspace/policy.jsonc"
oc "plugins enable policy"
as_user "$OC_USER" "openclaw config patch --stdin" <<'EOF'
{ plugins: { entries: { policy: { enabled: true, config: { enabled: true, path: "policy.jsonc", workspaceRepairs: false } } } } }
EOF
as_user "$OC_USER" "systemctl --user restart openclaw-gateway.service"; sleep 8
check="$(as_user "$OC_USER" "openclaw policy check --agent main --json" 2>/dev/null || true)"
okv="$(jq -r '.ok' <<<"$check" 2>/dev/null || echo false)"
if [[ "$okv" == "true" ]]; then
  ph="$(jq -r '.attestation.policy.hash' <<<"$check")"; ah="$(jq -r '.attestation.attestationHash' <<<"$check")"
  as_user "$OC_USER" "openclaw config patch --stdin" <<EOF
{ plugins: { entries: { policy: { config: { expectedHash: "$ph", expectedAttestationHash: "$ah" } } } } }
EOF
  ok "policy clean; hash-locked policy=$ph attestation=$ah"
  as_user "$OC_USER" "openclaw policy watch --agent main --once --json" >/dev/null && ok "policy watch: no drift" \
    || warn "policy watch reports drift right after locking — rerun 'openclaw policy check --agent main --json' and re-lock"
else
  warn "policy check not clean — fix findings, then rerun this script:"; echo "$check" | jq '.findings' 2>/dev/null || echo "$check"
fi

log "Gates"
for a in main builder reader lab; do echo "--- sandbox explain --agent $a"; oc "sandbox explain --agent $a" || true; done
oc "exec-policy show --verbose" || true
oc "security audit --deep" || true
warn "Expected audit findings: tools.elevated.allowFrom.webchat.wildcard (only if ENABLE_ELEVATED=1)."
warn "Fix anything else the audit reports before step 8 (exposure). 'openclaw security audit --fix' tightens permissions."

stamp 70-configure
