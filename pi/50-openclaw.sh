#!/usr/bin/env bash
# Phase 5 — install OpenClaw for openclaw_user (rootless install-cli.sh, bundled Node),
# onboard non-interactively with env-backed secrets, install the Gateway user service,
# and add the Pi drop-in. Run with sudo from the admin account.
source "$(dirname "$0")/../lib/common.sh"
require_root
uid="$(user_uid "$OC_USER")"; home="$(user_home "$OC_USER")"
# (OpenClaw lands in $home/.openclaw/bin/openclaw)

log "Installing OpenClaw $OPENCLAW_VERSION with Node $NODE_VERSION into $home/.openclaw (no sudo)"
as_user "$OC_USER" "curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh \
  | bash -s -- --prefix \"\$HOME/.openclaw\" --version '$OPENCLAW_VERSION' --node-version '$NODE_VERSION' --no-onboard"
as_user "$OC_USER" "openclaw --version"

# Interactive shells (sudo -iu openclaw_user) don't get ~/.openclaw/bin on PATH by default.
# Debian's ~/.profile is read by login shells unless ~/.bash_profile or ~/.bash_login exists.
prof="$home/.profile"
for f in "$home/.bash_profile" "$home/.bash_login"; do [[ -f "$f" ]] && { prof="$f"; break; }; done
pathline='export PATH="$HOME/.openclaw/bin:$PATH"   # added by openclaw-pi-setup'
if ! grep -qF '.openclaw/bin' "$prof" 2>/dev/null; then
  printf '\n%s\n' "$pathline" >>"$prof"; chown "$OC_USER:$OC_USER" "$prof"
  ok "added ~/.openclaw/bin to PATH in $prof"
fi

# Admin shortcut: `oc <args>` runs openclaw as openclaw_user with the same environment the scripts
# use (systemd --user, rootless Docker). A script, not an alias, so it also works from scripts.
# openclaw_user itself can't use it (no sudo rights); it runs `openclaw` directly.
write_file /usr/local/bin/oc 0755 root:root <<EOF
#!/bin/sh
# Installed by openclaw-pi-setup (pi/50-openclaw.sh). Usage: oc <openclaw args>
exec sudo -u $OC_USER -H env \\
  XDG_RUNTIME_DIR=/run/user/$uid \\
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \\
  DOCKER_HOST=unix:///run/user/$uid/docker.sock \\
  bash -lc 'umask 022; cd "\$HOME" && PATH="\$HOME/.openclaw/bin:\$PATH" exec openclaw "\$@"' oc "\$@"
EOF

log "Secrets -> $home/.openclaw/.env (600)"
install -d -m 700 -o "$OC_USER" -g "$OC_USER" "$home/.openclaw"
envf="$home/.openclaw/.env"
touch "$envf"; chown "$OC_USER:$OC_USER" "$envf"; chmod 600 "$envf"
if ! grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$envf"; then
  echo "OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)" >>"$envf"
  ok "generated a 64-hex-char gateway token"
fi
case "$AUTH_CHOICE" in
  custom)    keyvar=CUSTOM_API_KEY ;;     # verified: ref mode stores { source: env, id: CUSTOM_API_KEY }
  anthropic) keyvar=ANTHROPIC_API_KEY ;;
  openai)    keyvar=OPENAI_API_KEY ;;
  *) die "AUTH_CHOICE must be custom|anthropic|openai" ;;
esac
if ! grep -q "^$keyvar=" "$envf"; then
  read -r -s -p "Paste the $AUTH_CHOICE API key (stored only in $envf): " key; echo
  [[ -n "$key" ]] || die "empty key"
  printf '%s=%s\n' "$keyvar" "$key" >>"$envf"; unset key
fi

# OpenClaw refuses to install a service under a group/world-writable directory; tighten each one.
for d in "$home/.config" "$home/.config/systemd" "$home/.config/systemd/user"; do
  install -d -m 700 -o "$OC_USER" -g "$OC_USER" "$d"; chmod 700 "$d"
done
chmod 750 "$home"
# OpenClaw's service installer fingerprints every unit file including drop-ins and aborts if they
# appear mid-install. Move any earlier Pi drop-in aside; it is rewritten after onboarding below.
dropin="$home/.config/systemd/user/openclaw-gateway.service.d"
if [[ -d "$dropin" ]]; then
  rm -rf "$home/.cache/openclaw-gateway.service.d.bak"
  install -d -m 700 -o "$OC_USER" -g "$OC_USER" "$home/.cache"
  mv "$dropin" "$home/.cache/openclaw-gateway.service.d.bak"
  as_user "$OC_USER" "systemctl --user daemon-reload" || true
  warn "moved existing $dropin aside (rewritten after the service install)"
fi

log "Non-interactive onboarding (secret-input-mode ref: config holds env refs, not keys)"
common="--non-interactive --accept-risk --mode local --secret-input-mode ref \
  --gateway-bind loopback --install-daemon --daemon-runtime node --skip-bootstrap --skip-skills --json"
# Vision support is declared, not detected: only claim it if the model really takes images.
if [[ "${CUSTOM_IMAGE_INPUT:-0}" == "1" ]]; then img_flag="--custom-image-input"; else img_flag="--custom-text-input"; fi
case "$AUTH_CHOICE" in
  custom) auth="--auth-choice custom-api-key --custom-base-url '$CUSTOM_BASE_URL' --custom-model-id '$CUSTOM_MODEL_ID' \
                --custom-provider-id '$CUSTOM_PROVIDER_ID' --custom-compatibility '$CUSTOM_COMPATIBILITY' $img_flag" ;;
  anthropic) auth="--auth-choice apiKey" ;;
  openai)    auth="--auth-choice openai-api-key" ;;
esac
# Onboarding installs the Gateway service. Only ask before re-running when that service already
# exists; a half-finished earlier run (config written, no service) is always completed.
svc_exists=0
as_user "$OC_USER" "systemctl --user cat openclaw-gateway.service" >/dev/null 2>&1 && svc_exists=1
if [[ -f "$home/.openclaw/openclaw.json" && $svc_exists -eq 1 ]] \
   && ! confirm "OpenClaw is already onboarded (config + Gateway service exist). Re-run onboarding?"; then
  warn "skipping onboarding"
else
  # Re-runs keep the model sign-in already saved by a previous run (onboarding otherwise stores the
  # new key as an inactive replacement and stops before installing the Gateway service).
  if [[ -f "$home/.openclaw/openclaw.json" ]]; then auth="--auth-choice skip"; fi
  as_user "$OC_USER" "set -a; . \$HOME/.openclaw/.env; set +a; openclaw onboard $common $auth"
fi
as_user "$OC_USER" "openclaw models auth list" || true
as_user "$OC_USER" "openclaw secrets audit --check" || warn "secrets audit reported findings — read them above"

log "Gateway service drop-in for the Pi"
write_file "$home/.config/systemd/user/openclaw-gateway.service.d/10-pi.conf" 0644 "$OC_USER:$OC_USER" <<EOF
[Unit]
Wants=docker.service
After=docker.service

[Service]
Environment=OPENCLAW_NO_RESPAWN=1
Environment=NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
Environment=DOCKER_HOST=unix:///run/user/$uid/docker.sock
TimeoutStartSec=90
EOF
chown -R "$OC_USER:$OC_USER" "$home/.config/systemd"
as_user "$OC_USER" "systemctl --user daemon-reload && systemctl --user enable openclaw-gateway.service && systemctl --user restart openclaw-gateway.service"
# First start on a Pi is slow (compile cache, state DB): poll instead of a fixed sleep.
log "Waiting for the Gateway to listen on 127.0.0.1:18789 (up to 120 s)"
for _ in $(seq 1 40); do
  ss -ltnH 'sport = :18789' | grep -q . && break; sleep 3
done
if as_user "$OC_USER" "openclaw gateway status --deep --require-rpc"; then ok "gateway healthy"
else
  journalctl "_SYSTEMD_USER_UNIT=openclaw-gateway.service" -n 40 --no-pager || true
  die "gateway not healthy — see the log lines above"
fi

chmod 700 "$home/.openclaw"
stamp 50-openclaw
ok "OpenClaw installed. Don't expose it yet — images and config come next."
