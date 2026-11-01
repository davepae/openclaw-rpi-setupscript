#!/usr/bin/env bash
# Phase 0 — check the Pi is what the design assumes. Read-only; safe to rerun.
source "$(dirname "$0")/../lib/common.sh"
require_root

fail=0
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "$1 — FAILED ($2)"; fail=1; fi; }

log "Platform"
. /etc/os-release
[[ "${VERSION_CODENAME:-}" == "trixie" ]] && ok "Debian 13 trixie ($PRETTY_NAME)" || { warn "expected trixie, found ${VERSION_CODENAME:-unknown}"; fail=1; }
[[ "$(dpkg --print-architecture)" == "arm64" ]] && ok "arm64 userland" || { warn "not arm64 — 64-bit Pi OS is required"; fail=1; }
grep -q 'Raspberry Pi 5' /proc/device-tree/model 2>/dev/null && ok "$(tr -d '\0' </proc/device-tree/model)" || warn "not a Pi 5 (continuing)"

mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
ok "RAM ≈ ${mem_gb} GiB"
if (( mem_gb < 12 )); then
  warn "8 GB board: set SANDBOX_MEMORY=1536m and SANDBOX_CPUS=2 in settings.env (doc: halve caps)"
fi

root_src="$(findmnt -no SOURCE /)"
[[ "$root_src" == /dev/nvme* ]] && ok "root on NVMe ($root_src)" || warn "root is on $root_src — the design expects NVMe"

log "Kernel / cgroups"
check "cgroup v2 unified hierarchy" "[[ \$(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]]"
if grep -qw memory /sys/fs/cgroup/cgroup.controllers; then ok "memory controller available"
else warn "memory controller missing: add 'cgroup_enable=memory cgroup_memory=1' to /boot/firmware/cmdline.txt and reboot (flagged #7)"; fi
ok "page size $(getconf PAGESIZE) bytes (16384 = Pi 5 16K kernel; kernel=kernel8.img switches to 4K if a binary needs it)"

log "Power / thermals"
if command -v vcgencmd >/dev/null; then
  t="$(vcgencmd get_throttled | cut -d= -f2)"
  [[ "$t" == "0x0" ]] && ok "get_throttled=0x0" || { warn "get_throttled=$t — check PSU (27 W) and cooling"; fail=1; }
fi

log "Swap"
swapon --show || true
systemctl is-enabled rpi-swap >/dev/null 2>&1 && ok "rpi-swap present (keep default zram + file)" || warn "rpi-swap not found — Debian 13 Pi OS normally ships it"

log "Settings"
for v in ADMIN_USER OC_USER OPENCLAW_VERSION NODE_VERSION DNS_SERVERS; do
  [[ -n "${!v:-}" ]] && ok "$v=${!v}" || { warn "$v empty"; fail=1; }
done
id "$ADMIN_USER" >/dev/null 2>&1 || { warn "admin user $ADMIN_USER missing"; fail=1; }
[[ "$PRIMARY_MODEL" == *"<"* ]] && { warn "PRIMARY_MODEL still a placeholder"; fail=1; }

(( fail == 0 )) && { ok "preflight passed"; stamp 00-preflight; } || die "fix the items above, then rerun"
