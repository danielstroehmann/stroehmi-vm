#!/usr/bin/env bash
#
# set-hostname.sh - Change the hostname of an Ubuntu server (26.04).
#
#   * sets the static hostname (short name) via hostnamectl
#   * maps the FQDN and short name to 127.0.1.1 in /etc/hosts
#   * stops cloud-init from resetting the hostname / /etc/hosts on reboot
#
# FOR TEST / DEMO ENVIRONMENTS ONLY.
#
# Usage: sudo ./set-hostname.sh [options] [NEW_NAME]   (run with --help for details)

set -euo pipefail

CLOUD_CFG="/etc/cloud/cloud.cfg.d/99-demo-hostname.cfg"

NEW_NAME=""
ASSUME_YES=0

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'; C_OFF=$'\e[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

info() { echo "${C_BLUE}==>${C_OFF} $*"; }
ok()   { echo "${C_GREEN}[ok]${C_OFF} $*"; }
warn() { echo "${C_YELLOW}[warn]${C_OFF} $*" >&2; }
die()  { echo "${C_RED}[error]${C_OFF} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo $(basename "$0") [options] [NEW_NAME]

Changes the hostname of this Ubuntu server. NEW_NAME can be a short name
(demo01) or an FQDN (demo01.example.com). If it is missing, it is asked for.

Options:
  -n, --name NAME   new hostname or FQDN (same as NEW_NAME)
  -y, --yes         do not ask for confirmation
  -h, --help        show this help
EOF
}

# read from the terminal even when stdin is a pipe (e.g. curl | bash)
ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    prompt="${prompt} [${default}]"
  fi
  read -r -p "${prompt}: " answer </dev/tty || die "No terminal available for input - pass the values as options."
  echo "${answer:-$default}"
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local answer
  answer="$(ask "$1 (y/n)" "y")"
  [[ "$answer" =~ ^[YyJj] ]]
}

# short name or FQDN, labels per RFC 1123
valid_hostname() {
  local re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
  [[ ${#1} -le 253 && "$1" =~ $re ]]
}

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name) NEW_NAME="${2:-}"; shift 2 ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage; die "Unknown option: $1" ;;
    *)         NEW_NAME="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# pre-flight checks
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Please run as root (sudo $0)."

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
fi
if [[ "${ID:-}" != "ubuntu" ]]; then
  die "This script supports Ubuntu only (detected: ${PRETTY_NAME:-unknown})."
fi
if [[ "${VERSION_ID:-}" != "26.04" ]]; then
  warn "Written for Ubuntu 26.04, detected ${PRETTY_NAME:-unknown}."
  confirm "Continue anyway?" || exit 1
fi

# ---------------------------------------------------------------------------
# collect input
# ---------------------------------------------------------------------------
OLD_SHORT="$(hostname -s 2>/dev/null || hostname)"
OLD_FQDN="$(hostname -f 2>/dev/null || hostname)"

if [[ -z "$NEW_NAME" ]]; then
  info "Current hostname: ${OLD_SHORT} (FQDN: ${OLD_FQDN})"
  NEW_NAME="$(ask "New hostname or FQDN")"
fi
NEW_NAME="${NEW_NAME,,}"
NEW_NAME="${NEW_NAME%.}"
valid_hostname "$NEW_NAME" || die "Invalid hostname: '$NEW_NAME' (allowed: a-z, 0-9, '-', labels separated by '.')"

NEW_SHORT="${NEW_NAME%%.*}"
if [[ "$NEW_NAME" == *.* ]]; then
  NEW_FQDN="$NEW_NAME"
  HOSTS_LINE="127.0.1.1	${NEW_FQDN} ${NEW_SHORT}"
else
  NEW_FQDN=""
  HOSTS_LINE="127.0.1.1	${NEW_SHORT}"
fi

echo
info "Summary"
echo "  Old hostname : ${OLD_SHORT} (FQDN: ${OLD_FQDN})"
echo "  New hostname : ${NEW_SHORT}"
echo "  New FQDN     : ${NEW_FQDN:-(none - short name only)}"
echo "  /etc/hosts   : ${HOSTS_LINE}"
echo
confirm "Proceed?" || exit 1

# ---------------------------------------------------------------------------
# 1. hostname
# ---------------------------------------------------------------------------
info "Setting hostname to ${NEW_SHORT}"
if ! hostnamectl set-hostname "$NEW_SHORT" 2>/dev/null; then
  warn "hostnamectl failed - writing /etc/hostname directly"
  echo "$NEW_SHORT" >/etc/hostname
  hostname "$NEW_SHORT" 2>/dev/null || warn "Could not change the running hostname - takes effect after reboot."
fi

# ---------------------------------------------------------------------------
# 2. /etc/hosts
# ---------------------------------------------------------------------------
info "Updating /etc/hosts"
BACKUP="/etc/hosts.bak-$(date +%Y%m%d-%H%M%S)"
cp -p /etc/hosts "$BACKUP"
TMP_HOSTS="$(mktemp)"
trap 'rm -f "$TMP_HOSTS"' EXIT
# replace the first 127.0.1.1 entry, drop further ones, append if missing
awk -v line="$HOSTS_LINE" '
  $1 == "127.0.1.1" { if (!done) { print line; done = 1 } next }
  { print }
  END { if (!done) print line }
' "$BACKUP" >"$TMP_HOSTS"
# write in place (keeps owner/permissions and works when /etc/hosts is a bind mount)
cat "$TMP_HOSTS" >/etc/hosts
ok "Backup: $BACKUP"

# ---------------------------------------------------------------------------
# 3. cloud-init
# ---------------------------------------------------------------------------
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  info "Telling cloud-init to keep the hostname ($CLOUD_CFG)"
  cat >"$CLOUD_CFG" <<'EOF'
# Generated by set-hostname.sh - keep the manually set hostname and /etc/hosts
preserve_hostname: true
manage_etc_hosts: false
EOF
fi

# ---------------------------------------------------------------------------
# 4. verification
# ---------------------------------------------------------------------------
CUR_SHORT="$(hostname -s 2>/dev/null || hostname)"
CUR_FQDN="$(hostname -f 2>/dev/null || true)"
[[ "$CUR_SHORT" == "$NEW_SHORT" ]] && ok "hostname: $CUR_SHORT" || warn "hostname is '$CUR_SHORT' (expected '$NEW_SHORT')"
if [[ -n "$NEW_FQDN" ]]; then
  [[ "$CUR_FQDN" == "$NEW_FQDN" ]] && ok "FQDN: $CUR_FQDN" || warn "hostname -f returns '$CUR_FQDN' (expected '$NEW_FQDN')"
fi

echo
ok "Done."
echo "  Log out and back in to see the new name in your shell prompt."
if [[ -f /etc/apache2/conf-available/servername.conf ]] \
   && ! grep -qx "ServerName ${NEW_FQDN:-$NEW_SHORT}" /etc/apache2/conf-available/servername.conf; then
  echo
  warn "Apache is still configured for the old name - run init-apache.sh again with the new FQDN"
  warn "to get a matching vhost and certificate."
fi
