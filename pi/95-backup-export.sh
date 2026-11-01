#!/usr/bin/env bash
# Phase 9b — encrypted off-Pi backup copies. Run with sudo.
#   Encrypts each nightly backup in ~openclaw_user/backups to an age PUBLIC key and keeps the
#   encrypted copies in /var/backups/openclaw-export, readable by ADMIN_USER, for another
#   machine to pull with rsync. The Pi never holds the private key, so it can't decrypt them.
#   Needs BACKUP_AGE_RECIPIENT (an age1... public key) in config/settings.env; skipped without it.
#   Verified on a Pi 5 with OpenClaw 2026.10.8 and age 1.2.1 on 2026-11-01.
source "$(dirname "$0")/../lib/common.sh"
require_root

if [[ -z "${BACKUP_AGE_RECIPIENT:-}" ]]; then
  warn "BACKUP_AGE_RECIPIENT is empty: skipping encrypted backup export (see README 'Backups')."
  exit 0
fi
[[ "$BACKUP_AGE_RECIPIENT" =~ ^age1[0-9a-z]{58}$ ]] \
  || die "BACKUP_AGE_RECIPIENT doesn't look like an age public key (age1 followed by 58 characters)"

home="$(user_home "$OC_USER")"
export_dir="${BACKUP_EXPORT_DIR:-/var/backups/openclaw-export}"
id "$ADMIN_USER" >/dev/null 2>&1 || die "ADMIN_USER '$ADMIN_USER' doesn't exist on this machine"

log "Installing age"
command -v age >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends age
age --version

log "Export script -> /usr/local/sbin/openclaw-backup-export"
write_file /usr/local/sbin/openclaw-backup-export 0750 root:root <<EOF
#!/bin/sh
# Installed by openclaw-pi-setup (pi/95-backup-export.sh). Encrypts each OpenClaw backup to an
# age public key; prunes encrypted copies whose original the backup timer has deleted.
set -eu
RECIPIENT="$BACKUP_AGE_RECIPIENT"
SRC="$home/backups"
DST="$export_dir"
ADMIN="$ADMIN_USER"
install -d -m 750 -o root -g "\$ADMIN" "\$DST"
find "\$SRC" -maxdepth 1 -type f -name '*-openclaw-backup.tar.gz' | while read -r f; do
  out="\$DST/\$(basename "\$f").age"
  [ -e "\$out" ] && continue
  age -r "\$RECIPIENT" -o "\$out.tmp" "\$f" && mv "\$out.tmp" "\$out"
  chgrp "\$ADMIN" "\$out"; chmod 640 "\$out"
done
for o in "\$DST"/*.age; do
  [ -e "\$o" ] || continue
  [ -e "\$SRC/\$(basename "\$o" .age)" ] || rm -f "\$o"
done
EOF

log "Nightly timer at 04:15 (the backup timer runs at 02:30 plus up to 30 minutes)"
write_file /etc/systemd/system/openclaw-backup-export.service 0644 root:root <<'EOF'
[Unit]
Description=Encrypt OpenClaw backups for off-Pi copy

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openclaw-backup-export
EOF
write_file /etc/systemd/system/openclaw-backup-export.timer 0644 root:root <<'EOF'
[Unit]
Description=Nightly OpenClaw backup encryption

[Timer]
OnCalendar=*-*-* 04:15
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now openclaw-backup-export.timer
systemctl list-timers openclaw-backup-export.timer --no-pager

log "Encrypting existing backups now"
/usr/local/sbin/openclaw-backup-export
ls -la "$export_dir"
ok "Pull from another machine:  rsync -av --ignore-existing $ADMIN_USER@<pi>:$export_dir/ ~/Backups/openclaw/"
stamp 95-backup-export
