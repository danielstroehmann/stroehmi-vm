#!/usr/bin/env bash
#
# init-apache.sh - Set up a fresh Ubuntu server (26.04) as an Apache2 HTTPS demo host.
#
#   * installs all pending OS updates
#   * installs Apache2 with the required modules (ssl, headers, http2)
#   * creates a self-signed certificate for the given FQDN
#   * configures an HTTPS vhost plus an HTTP -> HTTPS redirect on port 80
#   * deploys one of the demo pages from ../homepage as index.html
#
# FOR TEST / DEMO ENVIRONMENTS ONLY - do not use in production.
#
# Usage: sudo ./init-apache.sh [options]   (run with --help for details)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMEPAGE_DIR="${HOMEPAGE_DIR:-${SCRIPT_DIR}/../homepage}"

WEB_ROOT="/var/www/html"
CERT_DIR="/etc/ssl/certs"
KEY_DIR="/etc/ssl/private"
CERT_DAYS=365
DEFAULT_GREETING="SHOWTIME"
DEFAULT_HOST_INFO="Hosting: Apache [Ubuntu]"
MAX_TEXT_LEN=30

FQDN=""
PAGE=""
GREETING=""
HOST_INFO=""
ASSUME_YES=0
SKIP_UPGRADE=0

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

Sets up Apache2 with HTTPS (self-signed certificate) and a demo homepage
on a fresh Ubuntu server. Missing values are asked for interactively.

Options:
  -f, --fqdn NAME         FQDN the server listens on (used for the certificate)
  -p, --page FILE|NUMBER  demo page from the homepage folder (e.g. index-racing-v2.html)
  -g, --greeting TEXT     greeting shown on the page     (default: "${DEFAULT_GREETING}")
  -i, --host-info TEXT    hosting info shown on the page (default: "${DEFAULT_HOST_INFO}")
  -y, --yes               do not ask for confirmation
      --skip-upgrade      skip "apt-get full-upgrade"
  -h, --help              show this help

Environment:
  HOMEPAGE_DIR            folder with the demo pages (default: <repo>/homepage)
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

valid_fqdn() {
  local re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
  [[ ${#1} -le 253 && "$1" =~ $re ]]
}

# restrict page texts to characters that are safe in a JS string, sed and the pixel fonts
valid_text() {
  local re='^[][A-Za-z0-9 .,:;!?()/_+#@&%*=-]*$'
  [[ ${#1} -le $MAX_TEXT_LEN && "$1" =~ $re ]]
}

page_title() {
  sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$1" | head -n 1
}

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--fqdn)      FQDN="${2:-}"; shift 2 ;;
    -p|--page)      PAGE="${2:-}"; shift 2 ;;
    -g|--greeting)  GREETING="${2:-}"; shift 2 ;;
    -i|--host-info) HOST_INFO="${2:-}"; shift 2 ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    --skip-upgrade) SKIP_UPGRADE=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage; die "Unknown option: $1" ;;
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

[[ -d "$HOMEPAGE_DIR" ]] || die "Homepage folder not found: $HOMEPAGE_DIR (clone the whole repository or set HOMEPAGE_DIR)."
HOMEPAGE_DIR="$(cd "$HOMEPAGE_DIR" && pwd)"
mapfile -t PAGES < <(find "$HOMEPAGE_DIR" -maxdepth 1 -type f -name '*.html' -printf '%f\n' | sort)
[[ ${#PAGES[@]} -gt 0 ]] || die "No .html files found in $HOMEPAGE_DIR."

# ---------------------------------------------------------------------------
# collect input
# ---------------------------------------------------------------------------
if [[ -z "$FQDN" ]]; then
  FQDN="$(ask "FQDN for this server (used for Apache and the certificate)" "$(hostname -f 2>/dev/null || true)")"
fi
FQDN="${FQDN,,}"
valid_fqdn "$FQDN" || die "Invalid FQDN: '$FQDN'"

if [[ -z "$PAGE" ]]; then
  echo
  info "Available demo pages in ${HOMEPAGE_DIR}:"
  for i in "${!PAGES[@]}"; do
    printf '  %2d) %-28s %s\n' "$((i + 1))" "${PAGES[$i]}" "$(page_title "$HOMEPAGE_DIR/${PAGES[$i]}")"
  done
  echo
  PAGE="$(ask "Select the page to use as index.html (1-${#PAGES[@]})")"
fi
if [[ "$PAGE" =~ ^[0-9]+$ ]]; then
  (( PAGE >= 1 && PAGE <= ${#PAGES[@]} )) || die "Invalid selection: $PAGE"
  PAGE="${PAGES[$((PAGE - 1))]}"
fi
PAGE="$(basename "$PAGE")"
[[ -f "$HOMEPAGE_DIR/$PAGE" ]] || die "Page not found: $HOMEPAGE_DIR/$PAGE"

if [[ -z "$GREETING" ]]; then
  if [[ $ASSUME_YES -eq 1 ]]; then GREETING="$DEFAULT_GREETING"
  else GREETING="$(ask "Greeting shown on the page (max ${MAX_TEXT_LEN} chars)" "$DEFAULT_GREETING")"; fi
fi
if [[ -z "$HOST_INFO" ]]; then
  if [[ $ASSUME_YES -eq 1 ]]; then HOST_INFO="$DEFAULT_HOST_INFO"
  else HOST_INFO="$(ask "Hosting info shown on the page (max ${MAX_TEXT_LEN} chars)" "$DEFAULT_HOST_INFO")"; fi
fi
valid_text "$GREETING"  || die "Greeting contains unsupported characters or is longer than ${MAX_TEXT_LEN} chars."
valid_text "$HOST_INFO" || die "Hosting info contains unsupported characters or is longer than ${MAX_TEXT_LEN} chars."

CERT_FILE="${CERT_DIR}/${FQDN}.crt"
KEY_FILE="${KEY_DIR}/${FQDN}.key"
SITE_CONF="/etc/apache2/sites-available/${FQDN}.conf"

echo
info "Summary"
echo "  FQDN         : $FQDN"
echo "  Page         : $PAGE ($(page_title "$HOMEPAGE_DIR/$PAGE"))"
echo "  Greeting     : $GREETING"
echo "  Hosting info : $HOST_INFO"
echo "  Certificate  : $CERT_FILE (self-signed, ${CERT_DAYS} days)"
echo "  OS upgrade   : $([[ $SKIP_UPGRADE -eq 1 ]] && echo skipped || echo yes)"
echo
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
# 2. apache
# ---------------------------------------------------------------------------
info "Installing Apache2"
apt-get "${APT_OPTS[@]}" install apache2 openssl curl

info "Enabling Apache modules"
a2enmod -q ssl headers http2 alias >/dev/null

# ---------------------------------------------------------------------------
# 3. self-signed certificate
# ---------------------------------------------------------------------------
if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
  warn "Certificate for $FQDN already exists - reusing $CERT_FILE"
else
  info "Creating self-signed certificate for $FQDN"
  OPENSSL_CNF="$(mktemp)"
  trap 'rm -f "$OPENSSL_CNF"' EXIT
  cat >"$OPENSSL_CNF" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = ${FQDN}

[v3]
subjectAltName       = DNS:${FQDN}
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature,keyEncipherment
extendedKeyUsage     = serverAuth
subjectKeyIdentifier = hash
EOF
  (umask 077; openssl req -x509 -quiet -newkey rsa:2048 -nodes -sha256 -days "$CERT_DAYS" \
    -config "$OPENSSL_CNF" -keyout "$KEY_FILE" -out "$CERT_FILE")
  chown root:root "$KEY_FILE" "$CERT_FILE"
  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"
  ok "Certificate: $CERT_FILE"
fi

# ---------------------------------------------------------------------------
# 4. vhost configuration
# ---------------------------------------------------------------------------
info "Writing Apache configuration $SITE_CONF"
echo "ServerName ${FQDN}" >/etc/apache2/conf-available/servername.conf
a2enconf -q servername >/dev/null

cat >"$SITE_CONF" <<EOF
# Generated by init-apache.sh - demo/test environment only

<VirtualHost *:80>
    ServerName ${FQDN}

    # redirect all plain HTTP requests to HTTPS
    Redirect permanent / https://${FQDN}/

    ErrorLog \${APACHE_LOG_DIR}/${FQDN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${FQDN}-access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName ${FQDN}
    DocumentRoot ${WEB_ROOT}
    Protocols h2 http/1.1

    SSLEngine on
    SSLCertificateFile    ${CERT_FILE}
    SSLCertificateKeyFile ${KEY_FILE}
    SSLProtocol           -all +TLSv1.2 +TLSv1.3
    SSLHonorCipherOrder   off

    <Directory ${WEB_ROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    ErrorLog \${APACHE_LOG_DIR}/${FQDN}-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/${FQDN}-ssl-access.log combined
</VirtualHost>
EOF

a2dissite -q 000-default default-ssl >/dev/null 2>&1 || true
a2ensite -q "$FQDN" >/dev/null

# ---------------------------------------------------------------------------
# 5. homepage
# ---------------------------------------------------------------------------
info "Deploying $PAGE as ${WEB_ROOT}/index.html"
sed_escape() { local s="${1//\\/\\\\}"; s="${s//&/\\&}"; echo "${s//|/\\|}"; }
install -d -m 755 "$WEB_ROOT"
sed -E \
  -e "s|^([[:space:]]*const GREETING[[:space:]]*=[[:space:]]*)\".*\";|\1\"$(sed_escape "$GREETING")\";|" \
  -e "s|^([[:space:]]*const HOST_INFO[[:space:]]*=[[:space:]]*)\".*\";|\1\"$(sed_escape "$HOST_INFO")\";|" \
  "$HOMEPAGE_DIR/$PAGE" >"${WEB_ROOT}/index.html"
chmod 644 "${WEB_ROOT}/index.html"

# ---------------------------------------------------------------------------
# 6. firewall + start
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  info "ufw is active - allowing ports 80 and 443"
  ufw allow "Apache Full" >/dev/null
fi

info "Checking configuration and restarting Apache"
apache2ctl configtest
systemctl enable --now apache2 >/dev/null 2>&1
systemctl restart apache2

# ---------------------------------------------------------------------------
# 7. verification
# ---------------------------------------------------------------------------
HTTPS_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --resolve "${FQDN}:443:127.0.0.1" "https://${FQDN}/" || true)"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --resolve "${FQDN}:80:127.0.0.1" "http://${FQDN}/" || true)"
[[ "$HTTPS_CODE" == "200" ]] && ok "HTTPS responds with 200" || warn "HTTPS check returned '$HTTPS_CODE'"
[[ "$HTTP_CODE" == "301" ]] && ok "HTTP redirects to HTTPS (301)" || warn "HTTP check returned '$HTTP_CODE'"

FINGERPRINT="$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 | cut -d= -f2)"

echo
ok "Done."
echo "  URL                : https://${FQDN}/"
echo "  Certificate        : $CERT_FILE"
echo "  Private key        : $KEY_FILE"
echo "  SHA-256 fingerprint: $FINGERPRINT"
echo "  Apache site config : $SITE_CONF"
echo
echo "  The certificate is self-signed - browsers will show a warning."
echo "  Make sure DNS (or /etc/hosts on the client) points ${FQDN} to this server."
if [[ -f /var/run/reboot-required ]]; then
  echo
  warn "A reboot is required to finish installing updates (sudo reboot)."
fi
