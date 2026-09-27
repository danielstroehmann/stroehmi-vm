#!/usr/bin/env bash
#
# init-ssh.sh - Set up the OpenSSH server on a fresh Ubuntu server (26.04) for demo use.
#
#   * installs all pending OS updates
#   * installs and enables openssh-server
#   * allows password login for ALL users, including root
#   * optionally sets a root password (root is locked on Ubuntu by default)
#
# FOR TEST / DEMO ENVIRONMENTS ONLY - password login for root is insecure.
#
# Usage: sudo ./init-ssh.sh [options]   (run with --help for details)

set -euo pipefail

# "00-" so it sorts before 50-cloud-init.conf: sshd uses the first value it reads
DROPIN="/etc/ssh/sshd_config.d/00-demo-password-auth.conf"

ASSUME_YES=0
SKIP_UPGRADE=0
SET_ROOT_PW=""   # "", yes, no

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
Usage: sudo $(basename "$0") [options]

Installs the OpenSSH server on a fresh Ubuntu server and allows password
login for all users, including root. For test/demo environments only.

Options:
      --root-password     set a new root password (asked interactively)
      --no-root-password  do not touch the root password
  -y, --yes               do not ask for confirmation
      --skip-upgrade      skip "apt-get full-upgrade"
  -h, --help              show this help

Environment:
  ROOT_PASSWORD           set this root password without prompting
                          (for automation - never store it in the repository)
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

# P = usable password, L = locked, NP = no password
root_pw_status() {
  passwd -S root 2>/dev/null | awk '{print $2}'
}

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-password)    SET_ROOT_PW="yes"; shift ;;
    --no-root-password) SET_ROOT_PW="no"; shift ;;
    -y|--yes)           ASSUME_YES=1; shift ;;
    --skip-upgrade)     SKIP_UPGRADE=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage; die "Unknown option: $1" ;;
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
ROOT_STATUS="$(root_pw_status)"
if [[ -n "${ROOT_PASSWORD:-}" ]]; then
  SET_ROOT_PW="yes"
elif [[ -z "$SET_ROOT_PW" ]]; then
  if [[ "$ROOT_STATUS" == "P" ]]; then
    SET_ROOT_PW="no"
  elif [[ $ASSUME_YES -eq 1 ]]; then
    SET_ROOT_PW="no"
  else
    warn "root has no usable password (status: ${ROOT_STATUS:-unknown}) - root cannot log in with a password yet."
    if confirm "Set a root password now?"; then SET_ROOT_PW="yes"; else SET_ROOT_PW="no"; fi
  fi
fi

echo
info "Summary"
echo "  Install            : openssh-server"
echo "  Password login     : enabled for all users"
echo "  Root login         : enabled (with password)"
echo "  Set root password  : ${SET_ROOT_PW}"
echo "  OS upgrade         : $([[ $SKIP_UPGRADE -eq 1 ]] && echo skipped || echo yes)"
echo
warn "Password login for root is insecure - use this on test/demo machines only."
confirm "Proceed?" || exit 1

# ---------------------------------------------------------------------------
# 1. system updates
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

info "Updating package lists"
apt-get update
if [[ $SKIP_UPGRADE -eq 0 ]]; then
  info "Installing all updates"
  apt-get "${APT_OPTS[@]}" full-upgrade
  apt-get -y autoremove
fi

# ---------------------------------------------------------------------------
# 2. openssh-server
# ---------------------------------------------------------------------------
info "Installing openssh-server"
apt-get "${APT_OPTS[@]}" install openssh-server

# ---------------------------------------------------------------------------
# 3. sshd configuration
# ---------------------------------------------------------------------------
info "Writing $DROPIN"
install -d -m 755 /etc/ssh/sshd_config.d
cat >"$DROPIN" <<'EOF'
# Generated by init-ssh.sh - demo/test environment only.
# Allows password login for all users, including root.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
PermitEmptyPasswords no
EOF
chmod 644 "$DROPIN"

# sshd needs its privilege separation dir to validate the config
install -d -m 755 /run/sshd
sshd -t || die "sshd configuration test failed - check $DROPIN"

# ---------------------------------------------------------------------------
# 4. root password
# ---------------------------------------------------------------------------
if [[ "$SET_ROOT_PW" == "yes" ]]; then
  info "Setting root password"
  if [[ -n "${ROOT_PASSWORD:-}" ]]; then
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
  else
    until passwd root </dev/tty; do
      warn "Password not set - please try again."
    done
  fi
  ok "root password set"
fi

# ---------------------------------------------------------------------------
# 5. firewall + start
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  info "ufw is active - allowing OpenSSH"
  ufw allow OpenSSH >/dev/null
fi

info "Enabling and restarting the SSH server"
systemctl daemon-reload
if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
  # Ubuntu default: socket activation - the socket listens, the service reads the config
  systemctl start ssh.socket
  systemctl try-restart ssh.service
else
  systemctl enable --now ssh.service >/dev/null 2>&1
  systemctl restart ssh.service
fi

# ---------------------------------------------------------------------------
# 6. verification
# ---------------------------------------------------------------------------
EFFECTIVE="$(sshd -T 2>/dev/null)"
check_setting() {
  local key="$1" want="$2" got
  got="$(awk -v k="$key" '$1 == k {print $2; exit}' <<<"$EFFECTIVE")"
  if [[ "$got" == "$want" ]]; then
    ok "$key $got"
  else
    warn "$key is '$got' (expected '$want') - another file in /etc/ssh/sshd_config.d may override it"
  fi
}
check_setting passwordauthentication yes
check_setting permitrootlogin yes

PORT="$(awk '$1 == "port" {print $2; exit}' <<<"$EFFECTIVE")"
ROOT_STATUS="$(root_pw_status)"

echo
ok "Done."
echo "  Connect with       : ssh <user>@$(hostname -f 2>/dev/null || hostname) -p ${PORT:-22}"
echo "  Config file        : $DROPIN"
if [[ "$ROOT_STATUS" != "P" ]]; then
  echo
  warn "root still has no usable password - set one with 'sudo passwd root' to allow root login."
fi
if [[ -f /var/run/reboot-required ]]; then
  echo
  warn "A reboot is required to finish installing updates (sudo reboot)."
fi
