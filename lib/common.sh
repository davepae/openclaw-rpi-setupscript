#!/usr/bin/env bash
# Shared helpers. Sourced by every script; not run directly.
set -Eeuo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BUNDLE_DIR

if [[ -f "$BUNDLE_DIR/config/settings.env" ]]; then
  # shellcheck source=/dev/null
  source "$BUNDLE_DIR/config/settings.env"
else
  echo "Missing $BUNDLE_DIR/config/settings.env — copy config/settings.env.example and edit it." >&2
  exit 1
fi

c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
log()  { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s ok%s %s\n'  "$c_ok"   "$c_off" "$*"; }
warn() { printf '%s !!%s %s\n'  "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%sERR%s %s\n'  "$c_err"  "$c_off" "$*" >&2; exit 1; }
trap 'die "failed at ${BASH_SOURCE[0]:-$0}:${LINENO}: ${BASH_COMMAND}"' ERR

require_root() { [[ $EUID -eq 0 ]] || die "run with sudo: sudo $0 $*"; }
require_not_root() { [[ $EUID -ne 0 ]] || die "run as a normal user, not root"; }

confirm() { # confirm "question" -> returns 0 on yes
  local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]];
}

user_uid()  { id -u "$1"; }
user_home() { getent passwd "$1" | cut -d: -f6; }

# Run a command as another user with a working systemd --user / rootless Docker env.
# PATH is set inside the shell: a login shell (bash -l) re-reads /etc/profile, which resets PATH.
# cd to the user's home: sudo keeps the caller's cwd, which the target user usually can't enter.
# umask 022: Debian's default 002 makes files group-writable, which OpenClaw's service installer rejects.
# Usage: as_user <user> <command...>   (command is passed to bash -lc)
as_user() {
  local u="$1"; shift
  local uid home; uid="$(user_uid "$u")"; home="$(user_home "$u")"
  [[ -d "/run/user/$uid" ]] || die "/run/user/$uid missing — is linger enabled for $u? (sudo loginctl enable-linger $u)"
  sudo -u "$u" -H env \
    HOME="$home" USER="$u" LOGNAME="$u" \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    DOCKER_HOST="unix:///run/user/$uid/docker.sock" \
    bash -lc "umask 022; cd \"$home\" && export PATH=\"$home/.openclaw/bin:$home/.local/bin:$home/bin:/usr/local/bin:/usr/bin:/bin\"; $*"
}

# Idempotently write a file only if content changed. write_file <path> <mode> <owner> < content
write_file() {
  local path="$1" mode="$2" owner="$3" tmp
  tmp="$(mktemp)"; cat >"$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 0; fi
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"; rm -f "$tmp"
  ok "wrote $path"
}

# Substitute @@VAR@@ placeholders from the environment into a template.
render() { # render <template>  -> stdout
  local line out
  out="$(cat "$1")"
  for v in $(grep -o '@@[A-Z_][A-Z0-9_]*@@' "$1" | sort -u | tr -d '@'); do
    [[ -n "${!v+x}" ]] || die "template $1 needs \$$v (set it in config/settings.env)"
    line="${!v}"; out="${out//@@$v@@/$line}"
  done
  printf '%s\n' "$out"
}

stamp() { mkdir -p "$BUNDLE_DIR/.state"; touch "$BUNDLE_DIR/.state/$1"; }
