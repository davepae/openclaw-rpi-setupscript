#!/usr/bin/env bash
# Phase 9 — maintenance timers (systemd user units for openclaw_user):
#   weekly  image rebuild (Debian security fixes, LibreOffice importer fixes) + sandbox recreate
#   daily   backup (archives include credentials — copy off the Pi, encrypted)
#   daily   policy drift check
#   weekly  security audit snapshot
source "$(dirname "$0")/../lib/common.sh"
require_root
home="$(user_home "$OC_USER")"; ud="$home/.config/systemd/user"
install -d -m 700 -o "$OC_USER" -g "$OC_USER" "$home/backups" "$home/.local/state/openclaw-audit"
oc="$home/.openclaw/bin/openclaw"

unit() { # unit <name> <OnCalendar> <ExecStart...>
  local name="$1" cal="$2"; shift 2
  write_file "$ud/$name.service" 0644 "$OC_USER:$OC_USER" <<EOF
[Unit]
Description=OpenClaw maintenance: $name

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=/bin/bash -lc '$*'
EOF
  write_file "$ud/$name.timer" 0644 "$OC_USER:$OC_USER" <<EOF
[Unit]
Description=Schedule $name

[Timer]
OnCalendar=$cal
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

unit openclaw-image-rebuild "Sun *-*-* 03:00:00" \
  "\$HOME/.cache/openclaw-images/bundle/pi/60-images.sh --rebuild && $oc sandbox recreate --all --force"
unit openclaw-backup "*-*-* 02:30:00" \
  "$oc backup create --verify --output \$HOME/backups && find \$HOME/backups -maxdepth 1 -name \"*-openclaw-backup.tar.gz\" -mtime +13 -delete"
# (--keep-daily/--keep-weekly apply only to uploads with --to <location>; local copies are pruned
#  with find: 14 days of nightly archives. Config-only snapshots live in backups/config.)
unit openclaw-policy-watch "*-*-* 06:00:00" \
  "$oc policy watch --agent main --once --json"
unit openclaw-audit "Mon *-*-* 05:00:00" \
  "$oc security audit --deep --json > \$HOME/.local/state/openclaw-audit/latest.json"

chown -R "$OC_USER:$OC_USER" "$home/.config/systemd"
as_user "$OC_USER" "systemctl --user daemon-reload && systemctl --user enable --now \
  openclaw-image-rebuild.timer openclaw-backup.timer openclaw-policy-watch.timer openclaw-audit.timer"
as_user "$OC_USER" "systemctl --user list-timers 'openclaw-*' --no-pager"
warn "Backups land in $home/backups and contain credentials. Set BACKUP_AGE_RECIPIENT and run pi/95-backup-export.sh to keep encrypted copies for another machine to pull."
stamp 90-timers
