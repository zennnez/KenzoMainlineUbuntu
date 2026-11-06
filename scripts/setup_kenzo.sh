#!/usr/bin/env bash
# ============================================================
# kenzo (Redmi Note 3 Pro) -- on-device setup: setup_kenzo.sh
#
# Runs ON THE PHONE (interactive) to finish bring-up that cannot
# be done at build time:
#   - passwords, sudo, default user pick/verify
#   - network routing via the USB link (Windows ICS, etc.)
#   - SSH authorized keys + sshd hardening
#   - Tailscale (optionally via Headscale)
#   - UFW enable
#   - Cloudflare tunnel / Oracle reverse tunnel
#   - default shell + git config
#
# Just want the Oracle tunnel?  (no other prompts)
#   ./setup_kenzo.sh --tunnel-only --oracle-host <oracle-ip> --oracle-domain app.example.com
# Keep THREE files together: setup_kenzo.sh, setup_oracle.sh and caddy_oracle (the Oracle
# Caddyfile). The tunnel port and the domains are read from caddy_oracle, so --oracle-domain
# is optional.
# It generates a tunnel-only key, configures Oracle over SSH if this device can log in
# there (--oracle-admin-key FILE, or a forwarded ssh-agent), otherwise prints ONE command
# to paste on Oracle, waits for it, starts the service and verifies the result.
#
# Packages, global config, Oh My Zsh, zshrc, helper scripts,
# ufw *installation* etc. are done at build-time via
# setup_rootfs.sh.
#
# Run as the default user (uses sudo) or as root (it will
# create/choose the default user, then re-run itself as that user).
# ============================================================

set -euo pipefail

ORIG_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration from .env or /etc/kenzo.env if present
ENV_LOADED=""
for _env in "${KENZO_ENV_FILE:-}" "${SCRIPT_DIR}/.env" "$PWD/.env" /etc/kenzo.env "$HOME/kenzo/.env" "$HOME/host/.env" "$HOME/.env" "${SCRIPT_DIR}/../.env"; do
    if [[ -n "$_env" && -f "$_env" && -r "$_env" ]]; then
        echo "Loading configuration from $_env..."
        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            line="$(echo "$raw_line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            [[ "$line" != *"="* ]] && continue
            key="${line%%=*}"
            val="${line#*=}"
            key="$(echo "$key" | tr -d '[:space:]')"
            [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && continue
            val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["\x27]//' -e 's/["\x27]$//')"
            if [ -z "$(eval "echo \"\${$key:-}\"")" ]; then
                export "$key=$val"
            fi
        done < "$_env"
        ENV_LOADED="$_env"
        export KENZO_ENV_FILE="$_env"
        break
    fi
done

DEFAULT_USER="${KENZO_USER:-${HOST_USER:-}}"
USER_PASS="${KENZO_USER_PASSWORD:-}"; SKIP_USER_PASS=0
ROOT_PASS="${KENZO_ROOT_PASSWORD:-}"; SKIP_ROOT_PASS=0
NOPASSWD_SUDO=""
SSH_KEYGEN=""                 # yes|no  generate a keypair ON the device
KEY_PASSPHRASE=""; PASSPHRASE_SET=0
EXTRA_PUBKEY="${KENZO_SSH_PUBKEY:-}"; EXTRA_PUBKEY_SET=0
[[ -n "$EXTRA_PUBKEY" ]] && EXTRA_PUBKEY_SET=1
DISABLE_ROOT_SSH=""           # yes|no
KEY_ONLY_SSH=""               # yes|no  (disable SSH password login)
INSTALL_TAILSCALE=""
HEADSCALE_URL=""; HEADSCALE_URL_SET=0
TAILSCALE_AUTHKEY=""
ENABLE_UFW=""
INSTALL_DOCKER=""
LAN_SUBNET=""; LAN_SUBNET_SET=0
USB_SUBNET="192.168.7.0/24"   # the RNDIS link to the PC (see usb-gadget-rndis.sh)
INSTALL_CLOUDFLARE=""
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
INSTALL_ORACLE_TUNNEL=""
ORACLE_HOST="${ORACLE_HOST:-}"
ORACLE_USER_SET=0; if [ -n "${ORACLE_USER:-}" ]; then ORACLE_USER_SET=1; fi
ORACLE_USER="${ORACLE_USER:-ubuntu}"
ORACLE_SSH_PORT="${ORACLE_SSH_PORT:-22}"
ORACLE_LOCAL_PORT="${ORACLE_LOCAL_PORT:-80}"
ORACLE_REMOTE_PORT_SET=0; if [ -n "${ORACLE_REMOTE_PORT:-}" ]; then ORACLE_REMOTE_PORT_SET=1; fi
ORACLE_REMOTE_PORT="${ORACLE_REMOTE_PORT:-8080}"
ORACLE_CADDYFILE="${ORACLE_CADDYFILE:-}"    # path to caddy_oracle (auto-detected), "none" = ignore it
ORACLE_DOMAIN_LIST=()                       # domains Caddy on Oracle should publish (optional)
if [ -n "${ORACLE_DOMAINS:-}" ]; then read -r -a ORACLE_DOMAIN_LIST <<< "${ORACLE_DOMAINS//,/ }"; fi
ORACLE_ADMIN_KEY="${ORACLE_ADMIN_KEY:-}"    # key that can log in to Oracle as admin (automatic setup)
ORACLE_ADMIN_USER="${ORACLE_ADMIN_USER:-}"  # default: same as --oracle-user
ORACLE_SCRIPT="${ORACLE_SCRIPT:-}"          # path to setup_oracle.sh (auto-detected)
ORACLE_PASSWORD_LOGIN="${ORACLE_PASSWORD_LOGIN:-}"   # yes = log in to Oracle with the admin PASSWORD (ssh prompts once)
ORACLE_WAIT="${ORACLE_WAIT:-}"              # seconds to wait for manual key authorization
TUNNEL_ONLY=0

usage() {
    cat << 'USAGEEOF'
Usage: setup_kenzo.sh [options]

Anything not passed as a flag is asked for interactively.

Accounts (root phase -- only when the script is started as root)
  --user NAME                 Default (non-root) user to create/use
  --user-pass PASS            Password for that user      (--skip-user-pass to leave as is)
  --root-pass PASS            Password for root           (--skip-root-pass to leave as is)
  --nopasswd-sudo yes|no      Passwordless sudo for the default user

SSH
  --extra-pubkey KEY          Authorize this public key (e.g. from your Windows PC)
  --generate-ssh-key yes|no   Also generate a keypair on the device
  --passphrase PASS           Passphrase for that generated key
  --disable-root-ssh yes|no   PermitRootLogin no
  --key-only-ssh yes|no       Disable SSH password login (needs an authorized key)

Network / security
  --install-tailscale yes|no  (--skip-tailscale = no)
  --headscale-url URL         Headscale control server (blank = tailscale.com)
  --tailscale-authkey KEY     Pre-auth key for non-interactive 'tailscale up'
  --install-docker yes|no     Install/enable Docker daemon (default: no, skip on weak device)
  --skip-docker               Skip Docker installation and disable daemon
  --ufw yes|no                Enable UFW (allows usb0 + tailscale0 inbound)
  --lan-subnet CIDR           Extra subnet to whitelist / allow SSH from (e.g. Wi-Fi LAN)
  --install-cloudflare yes|no / --cloudflare-token TOKEN / --skip-cloudflare
  --install-oracle-tunnel yes|no / --skip-oracle-tunnel
                              (giving --oracle-host implies yes)
  --tunnel-only               Do ONLY the Oracle tunnel (skips users/SSH/tailscale/ufw/...)
  --oracle-host H  --oracle-user U  --oracle-ssh-port P
  --oracle-local-port P       Port on THIS device your reverse proxy listens on (default 80)
  --oracle-remote-port P      Port bound on the Oracle side, 127.0.0.1 only (default 8080)
  --oracle-domain D           Domain for Oracle's Caddy (repeatable, or comma list). Only needed when
                              there is NO caddy_oracle; with one, domains come from it. Also used for
                              the end-to-end HTTPS check at the end.
  --oracle-admin-key FILE     Key that can log in to Oracle as admin: lets this script
                              configure Oracle (key, Caddy, firewall) with no manual step.
                              (A forwarded ssh-agent, ssh -A, works too.)
  --oracle-admin-user U       Admin login on Oracle (default: --oracle-user)
  --oracle-password           Log in to Oracle as admin with a PASSWORD (asked once by ssh; needs
                              PasswordAuthentication yes in Oracle's sshd_config). The tunnel
                              itself always uses its own key.
  --oracle-script PATH        setup_oracle.sh to run on Oracle (default: found next to this script)
  --oracle-caddyfile PATH     Caddyfile for Oracle (default: caddy_oracle next to this script; `none` to
                              skip). Oracle's Caddy is configured from it; the tunnel port and the
                              domains are read from it.
  --oracle-wait SECONDS       How long to wait for a manual key authorization (default 300)

  -h, --help
USAGEEOF
}

while [ $# -gt 0 ]; do
    case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
    case "$1" in
        --user)                DEFAULT_USER="${2:-}"; shift 2 ;;
        --user-pass)           USER_PASS="${2:-}"; shift 2 ;;
        --skip-user-pass)      SKIP_USER_PASS=1; shift ;;
        --root-pass)           ROOT_PASS="${2:-}"; shift 2 ;;
        --skip-root-pass)      SKIP_ROOT_PASS=1; shift ;;
        --nopasswd-sudo)       NOPASSWD_SUDO="${2:-}"; shift 2 ;;
        --extra-pubkey)        EXTRA_PUBKEY="${2:-}"; EXTRA_PUBKEY_SET=1; shift 2 ;;
        --generate-ssh-key)    SSH_KEYGEN="${2:-yes}"; shift 2 ;;
        --skip-ssh-key)        SSH_KEYGEN="no"; shift ;;
        --passphrase)          KEY_PASSPHRASE="${2:-}"; PASSPHRASE_SET=1; shift 2 ;;
        --disable-root-ssh)    DISABLE_ROOT_SSH="${2:-}"; shift 2 ;;
        --key-only-ssh)        KEY_ONLY_SSH="${2:-}"; shift 2 ;;
        --install-tailscale)   INSTALL_TAILSCALE="${2:-}"; shift 2 ;;
        --skip-tailscale)      INSTALL_TAILSCALE="no"; shift ;;
        --headscale-url)       HEADSCALE_URL="${2:-}"; HEADSCALE_URL_SET=1; shift 2 ;;
        --tailscale-authkey)   TAILSCALE_AUTHKEY="${2:-}"; shift 2 ;;
        --install-docker)      INSTALL_DOCKER="${2:-}"; shift 2 ;;
        --skip-docker)         INSTALL_DOCKER="no"; shift ;;
        --ufw)                 ENABLE_UFW="${2:-}"; shift 2 ;;
        --lan-subnet)          LAN_SUBNET="${2:-}"; LAN_SUBNET_SET=1; shift 2 ;;
        --install-cloudflare)  INSTALL_CLOUDFLARE="${2:-}"; shift 2 ;;
        --cloudflare-token)    CLOUDFLARE_TUNNEL_TOKEN="${2:-}"; shift 2 ;;
        --skip-cloudflare)     INSTALL_CLOUDFLARE="no"; shift ;;
        --install-oracle-tunnel) INSTALL_ORACLE_TUNNEL="${2:-}"; shift 2 ;;
        --skip-oracle-tunnel)  INSTALL_ORACLE_TUNNEL="no"; shift ;;
        --oracle-host)         ORACLE_HOST="${2:-}"; shift 2 ;;
        --oracle-user)         ORACLE_USER="${2:-}"; ORACLE_USER_SET=1; shift 2 ;;
        --oracle-ssh-port)     ORACLE_SSH_PORT="${2:-}"; shift 2 ;;
        --oracle-local-port)   ORACLE_LOCAL_PORT="${2:-}"; shift 2 ;;
        --oracle-remote-port)  ORACLE_REMOTE_PORT="${2:-}"; ORACLE_REMOTE_PORT_SET=1; shift 2 ;;
        --oracle-caddyfile)    ORACLE_CADDYFILE="${2:-}"; shift 2 ;;
        --oracle-domain)       read -r -a _doms <<< "${2//,/ }"; ORACLE_DOMAIN_LIST+=("${_doms[@]}"); shift 2 ;;
        --oracle-admin-key)    ORACLE_ADMIN_KEY="${2:-}"; shift 2 ;;
        --oracle-admin-user)   ORACLE_ADMIN_USER="${2:-}"; shift 2 ;;
        --oracle-script)       ORACLE_SCRIPT="${2:-}"; shift 2 ;;
        --oracle-password)     ORACLE_PASSWORD_LOGIN="yes"; shift ;;
        --oracle-wait)         ORACLE_WAIT="${2:-}"; shift 2 ;;
        --tunnel-only)         TUNNEL_ONLY=1; INSTALL_ORACLE_TUNNEL="yes"; shift ;;
        -h|--help)             usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

normalize_yesno() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        y|yes|true|1) echo yes ;;
        *) echo no ;;
    esac
}
for v in NOPASSWD_SUDO SSH_KEYGEN DISABLE_ROOT_SSH KEY_ONLY_SSH INSTALL_TAILSCALE \
         INSTALL_DOCKER ENABLE_UFW INSTALL_CLOUDFLARE INSTALL_ORACLE_TUNNEL; do
    [ -n "${!v}" ] && printf -v "$v" '%s' "$(normalize_yesno "${!v}")"
done

ask_yn() {
    local var="$1" q="$2" def="$3" ans hint="[y/N]"
    [ -n "${!var}" ] && return 0
    if [ ! -t 0 ]; then printf -v "$var" '%s' "$def"; return 0; fi
    [ "$def" = yes ] && hint="[Y/n]"
    read -r -p "$q $hint: " ans
    case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
        y|yes) printf -v "$var" yes ;;
        n|no)  printf -v "$var" no ;;
        *)     printf -v "$var" '%s' "$def" ;;
    esac
}

ask_secret() {
    local var="$1" label="$2" a b
    [ -t 0 ] || return 1
    while true; do
        read -r -s -p "$label (blank = leave unchanged): " a; echo
        [ -z "$a" ] && return 1
        read -r -s -p "Confirm: " b; echo
        [ "$a" = "$b" ] && { printf -v "$var" '%s' "$a"; return 0; }
        echo "Didn't match -- try again."
    done
}

valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$1" != root ]; }

# Re-run this script as USER. Passes along the .env path, the original script directory
# and a copy of setup_oracle.sh (sudo would otherwise drop the env / the scripts live in /root).
reexec_as() {   # reexec_as USER [extra args...]
    local u="$1" run_copy="/tmp/.setup_kenzo_run.sh" oracle_copy="" caddy_copy=""
    shift
    cp "$0" "$run_copy"; chmod 755 "$run_copy"
    if [ -z "${ORACLE_SCRIPT:-}" ] && [ -f "$SCRIPT_DIR/setup_oracle.sh" ]; then
        oracle_copy="/tmp/.setup_oracle_src.sh"
        cp "$SCRIPT_DIR/setup_oracle.sh" "$oracle_copy"; chmod 644 "$oracle_copy"
    fi
    if [ -z "${ORACLE_CADDYFILE:-}" ] && [ -f "$SCRIPT_DIR/caddy_oracle" ]; then
        caddy_copy="/tmp/.caddy_oracle_src"
        cp "$SCRIPT_DIR/caddy_oracle" "$caddy_copy"; chmod 644 "$caddy_copy"
    fi
    echo "Re-running setup as $u..."
    exec sudo -u "$u" -H env KENZO_ENV_FILE="${KENZO_ENV_FILE:-}" KENZO_ORIG_DIR="$SCRIPT_DIR" \
        ORACLE_SCRIPT="${ORACLE_SCRIPT:-$oracle_copy}" ORACLE_CADDYFILE="${ORACLE_CADDYFILE:-$caddy_copy}" bash "$run_copy" "${ORIG_ARGS[@]}" --user "$u" "$@"
}

# ============================================================
# Root phase: pick / create the default user, then hand over to it
# ============================================================

if [ "$(id -u)" -eq 0 ]; then
    echo "=================================================="
    echo " kenzo setup: default user"
    echo "=================================================="

    if ! command -v sudo >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y sudo
    fi

    if [ "$TUNNEL_ONLY" -eq 1 ]; then
        # No passwords/docker/sudo questions: just continue as the existing default user.
        TO_USER="${DEFAULT_USER:-$(getent passwd 1000 | cut -d: -f1 || true)}"
        if [ -n "$TO_USER" ] && valid_username "$TO_USER" && id -u "$TO_USER" >/dev/null 2>&1; then
            reexec_as "$TO_USER"
        fi
        echo "No regular user exists yet -- creating one first (normal flow), then the tunnel."
    fi

    if [ -z "$DEFAULT_USER" ]; then
        SUGGEST="$(getent passwd 1000 | cut -d: -f1 || true)"
        SUGGEST="${SUGGEST:-kenzo}"
        if [ -t 0 ]; then
            while true; do
                read -r -p "Default (non-root) username [${SUGGEST}]: " DEFAULT_USER
                DEFAULT_USER="${DEFAULT_USER:-$SUGGEST}"
                valid_username "$DEFAULT_USER" && break
                echo "Invalid name (lowercase letters, digits, _ or -; not 'root')."
                DEFAULT_USER=""
            done
        else
            DEFAULT_USER="$SUGGEST"
        fi
    fi
    valid_username "$DEFAULT_USER" || { echo "Invalid username '$DEFAULT_USER'." >&2; exit 1; }

    if id -u "$DEFAULT_USER" >/dev/null 2>&1; then
        echo "User '$DEFAULT_USER' already exists (UID $(id -u "$DEFAULT_USER"))."
    else
        UID_ARG=()
        getent passwd 1000 >/dev/null 2>&1 || UID_ARG=(-u 1000)
        useradd -m "${UID_ARG[@]}" -s /bin/bash "$DEFAULT_USER"
        echo "Created user '$DEFAULT_USER' (UID $(id -u "$DEFAULT_USER"))."
    fi
    mkdir -p "/home/$DEFAULT_USER"; chown "$DEFAULT_USER:$DEFAULT_USER" "/home/$DEFAULT_USER"

    if [ "$SKIP_USER_PASS" -eq 0 ]; then
        if [ -z "$USER_PASS" ]; then ask_secret USER_PASS "Password for $DEFAULT_USER" || true; fi
        if [ -n "$USER_PASS" ]; then
            printf '%s:%s\n' "$DEFAULT_USER" "$USER_PASS" | chpasswd
            echo "Password set for $DEFAULT_USER."
        fi
    fi
    if [ "$SKIP_ROOT_PASS" -eq 0 ]; then
        if [ -z "$ROOT_PASS" ]; then ask_secret ROOT_PASS "Password for root" || true; fi
        if [ -n "$ROOT_PASS" ]; then
            printf 'root:%s\n' "$ROOT_PASS" | chpasswd
            echo "Root password set."
        fi
    fi

    ask_yn INSTALL_DOCKER "Install and configure Docker?" no
    TARGET_GROUPS=(sudo video audio input render)
    if [ "$INSTALL_DOCKER" = yes ]; then
        getent group docker >/dev/null 2>&1 || groupadd docker 2>/dev/null || true
        TARGET_GROUPS+=(docker)
    fi
    for g in "${TARGET_GROUPS[@]}"; do
        getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$DEFAULT_USER"
    done

    PW_STATE="$(passwd -S "$DEFAULT_USER" 2>/dev/null | awk '{print $2}' || true)"
    if [ "$PW_STATE" != "P" ] && [ "$NOPASSWD_SUDO" != "yes" ]; then
        echo "NOTE: $DEFAULT_USER has no password -> enabling passwordless sudo."
        NOPASSWD_SUDO=yes
    fi
    ask_yn NOPASSWD_SUDO "Passwordless sudo for $DEFAULT_USER?" no
    install -d -m 750 /etc/sudoers.d
    SUDOERS_FILE="/etc/sudoers.d/90-${DEFAULT_USER}-nopasswd"
    if [ "$NOPASSWD_SUDO" = yes ]; then
        echo "${DEFAULT_USER} ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"
        visudo -cf "$SUDOERS_FILE" >/dev/null || { rm -f "$SUDOERS_FILE"; echo "sudoers check failed, removed" >&2; }
    else
        rm -f "$SUDOERS_FILE"
    fi

    # Mask broken/incomplete services if configured
    if [[ "${SKIP_BROKEN:-true}" == "true" ]]; then
        systemctl mask ModemManager.service 2>/dev/null || true
        systemctl stop ModemManager.service 2>/dev/null || true
    fi

    reexec_as "$DEFAULT_USER" --install-docker "$INSTALL_DOCKER"
    echo "ERROR: failed to re-exec as $DEFAULT_USER; aborting rather than continuing as root." >&2
    exit 1
fi

# ============================================================
# From here on: running as the default (non-root) user
# ============================================================

if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: 'sudo' is not installed. Run this script as root once (it installs sudo and creates the user)." >&2
    exit 1
fi
SUDO="sudo"
echo "Running as $(id -un). sudo may ask for this user's password."
# `sudo -v` insists on a password even with NOPASSWD when the user also matches the %sudo rule,
# so try the passwordless form first.
{ $SUDO -n true 2>/dev/null || $SUDO -v; } || { echo "ERROR: $(id -un) can't use sudo (not in the sudo group?)." >&2; exit 1; }
( while true; do sleep 50; sudo -n true 2>/dev/null || exit; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

if [[ "${SKIP_BROKEN:-true}" == "true" ]]; then
    $SUDO systemctl mask ModemManager.service 2>/dev/null || true
    $SUDO systemctl stop ModemManager.service 2>/dev/null || true
fi

ME="$(id -un)"
. /etc/os-release 2>/dev/null || true
CODENAME="${VERSION_CODENAME:-resolute}"
ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64) DEB_ARCH="arm64";  FASTFETCH_ARCH="aarch64" ;;
    armv7l|armhf)  DEB_ARCH="armhf";  FASTFETCH_ARCH="armhf"   ;;
    x86_64)        DEB_ARCH="amd64";  FASTFETCH_ARCH="amd64"   ;;
    *) echo "WARNING: unrecognized architecture '$ARCH' -- assuming arm64"; DEB_ARCH="arm64"; FASTFETCH_ARCH="aarch64" ;;
esac
echo "Detected architecture: $ARCH (deb arch: $DEB_ARCH)"

# ============================================================
# Helpers: apt, clock, network
# ============================================================

APT_OPTS=()
apt_install() { $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_OPTS[@]}" "$@"; }
apt_update()  { $SUDO apt-get update "${APT_OPTS[@]}"; }
apt_install_best_effort() {
    apt_install "$@" && return 0
    echo "Bulk install failed -- retrying one by one..."
    local p; for p in "$@"; do apt_install "$p" || echo "WARNING: could not install '$p'" >&2; done
}

tcp_ok() { timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

ensure_network() {
    local gw ans IFACE usb_addr=""
    if [ -z "$(ip route show default 2>/dev/null)" ]; then
        echo "No default route (the phone only has the USB link to your PC)."
        usb_addr="$(ip -o -4 addr show | awk '/ 192\.168\./ && $2 ~ /^usb/ {print $4; exit}' || true)"
        if [ -t 0 ]; then
            read -r -p "Add a default route via the PC end of the USB link? Gateway [192.168.7.1] (n = skip): " gw
            case "$gw" in n|N) gw="" ;; "") gw="192.168.7.1" ;; esac
        else
            if [ -n "$usb_addr" ]; then
                gw="192.168.7.1"
                echo "Non-interactive: adding default route via $gw (detected link $usb_addr)."
            fi
        fi
        if [ -n "$gw" ]; then
            IFACE="$(ip -o -4 addr show | awk '/ 192\.168\./{print $2; exit}' || true)"
            $SUDO ip route replace default via "$gw" ${IFACE:+dev "$IFACE"} || true
            if ! tcp_ok 1.1.1.1 443 2>/dev/null; then
                IFACE="${IFACE:-usb0}"
                $SUDO ip addr flush dev "$IFACE" 2>/dev/null || true
                $SUDO ip addr add 192.168.137.2/24 dev "$IFACE" 2>/dev/null || true
                $SUDO ip route replace default via 192.168.137.1 dev "$IFACE" 2>/dev/null || true
            fi
        fi
    fi
    if ! tcp_ok 1.1.1.1 443; then
        cat << 'NETHELP' >&2

No internet from the phone. Packages/tooling were pre-installed at build-time,
so most of this setup does not need it. Sections that do (Tailscale, GitHub, ...)
will individually report being skipped / unavailable.

To get connectivity, share your PC's network with the USB RNDIS link:
  Windows: Network Connections -> your Wi-Fi/Ethernet -> Properties -> Sharing
           -> "Allow other users to connect..." -> pick the RNDIS adapter.
           Windows sets that adapter to 192.168.137.1/24, so on the phone:
             sudo ip addr flush dev usb0
             sudo ip addr add 192.168.137.2/24 dev usb0
             sudo ip route replace default via 192.168.137.1
  (or bring up Wi-Fi / another uplink on the phone first).
NETHELP
    fi
    if ! getent hosts ports.ubuntu.com >/dev/null 2>&1; then
        echo "DNS isn't working -- setting public resolvers."
        if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
            IFACE="$(ip -o route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
            $SUDO resolvectl dns "${IFACE:-usb0}" 1.1.1.1 8.8.8.8 || true
        else
            $SUDO rm -f /etc/resolv.conf
            printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | $SUDO tee /etc/resolv.conf >/dev/null
        fi
    fi
}

CLOCK_MIN=1767225600
clock_bad() { [ "$(date +%s)" -lt "$CLOCK_MIN" ]; }
sync_clock() {
    clock_bad || return 0
    echo "System clock looks wrong ($(date)); fixing from an HTTP Date header..."
    local d
    d="$(curl -fsSI --max-time 10 http://ports.ubuntu.com/ubuntu-ports/ 2>/dev/null \
        | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r' || true)"
    if [ -n "$d" ] && $SUDO date -u -s "$d" >/dev/null 2>&1; then
        echo "Clock set to: $(date)"
        APT_OPTS=()
    else
        echo "WARNING: couldn't set the clock; TLS downloads may fail. Fix with: sudo date -s '...'"
    fi
}

# ============================================================
# Oracle relay tunnel (SSH reverse tunnel via autossh)
# ============================================================
#   Internet -> Oracle (public IP, Caddy + Let's Encrypt)
#            -> SSH reverse tunnel, dialed OUT from this device (fine behind CGNAT)
#            -> this device's reverse proxy on ORACLE_LOCAL_PORT
#
# Flow: 1) ask only for what is missing   2) dedicated tunnel-only SSH key
#       3) get the key (and Caddy) onto Oracle: automatically over SSH when this
#          device can log in there, else ONE paste-able command + wait for it
#       4) install + start the service      5) verify (end-to-end if domains known)

PROBE_ERR=""
TUNNEL_KEY=""

probe_tunnel_key() {
    PROBE_ERR="$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes -i "$TUNNEL_KEY" -p "$ORACLE_SSH_PORT" \
        "${ORACLE_USER}@${ORACLE_HOST}" true 2>&1 </dev/null)" || return 1
    return 0
}

explain_probe() {
    case "$PROBE_ERR" in
        *"Permission denied"*)  echo "reached Oracle, but the tunnel key isn't authorized there yet" ;;
        *"timed out"*)          echo "timed out reaching ${ORACLE_HOST}:${ORACLE_SSH_PORT} -- check the IP, and that TCP ${ORACLE_SSH_PORT} is open in the Oracle VCN Security List" ;;
        *"Connection refused"*) echo "connection refused -- sshd isn't listening on port ${ORACLE_SSH_PORT}" ;;
        *"Could not resolve"*)  echo "can't resolve '${ORACLE_HOST}' (DNS, or no internet?)" ;;
        *"IDENTIFICATION HAS CHANGED"*) echo "Oracle's SSH host key changed (VPS rebuilt?) -- run: ssh-keygen -R ${ORACLE_HOST}" ;;
        *) echo "ssh said: ${PROBE_ERR##*$'\n'}" ;;
    esac
}

find_oracle_script() {
    local c
    for c in "${ORACLE_SCRIPT:-}" "${KENZO_ORIG_DIR:+$KENZO_ORIG_DIR/setup_oracle.sh}" \
             "$SCRIPT_DIR/setup_oracle.sh" "$PWD/setup_oracle.sh" "$HOME/setup_oracle.sh" \
             "$HOME/kenzo/setup_oracle.sh" "$HOME/host/setup_oracle.sh"; do
        if [ -n "$c" ] && [ -r "$c" ]; then echo "$c"; return 0; fi
    done
    return 1
}

find_oracle_caddyfile() {
    local c
    if [ "${ORACLE_CADDYFILE:-}" = none ]; then return 1; fi
    for c in "${ORACLE_CADDYFILE:-}" "${KENZO_ORIG_DIR:+$KENZO_ORIG_DIR/caddy_oracle}" \
             "$SCRIPT_DIR/caddy_oracle" "$PWD/caddy_oracle" "$HOME/caddy_oracle" \
             "$HOME/kenzo/caddy_oracle" "$HOME/host/caddy_oracle"; do
        if [ -n "$c" ] && [ -r "$c" ]; then echo "$c"; return 0; fi
    done
    return 1
}

caddyfile_ports() {   # ports the Caddyfile proxies to on 127.0.0.1 (comments ignored)
    sed 's/#.*//' "$1" | grep -oE 'reverse_proxy[[:space:]]+127\.0\.0\.1:[0-9]+' | grep -oE '[0-9]+$' | sort -un || true
}

# Log in to Oracle as an ADMIN and run `setup_oracle.sh relay` there. Login order: key (given key,
# forwarded agent, ~/.ssh/id_*), then -- if allowed -- the admin password. One ssh connection is
# opened and reused (ControlMaster), so a password is asked for only once.
# Returns 0 only if everything worked.
oracle_admin_setup() {
    local admin_user="${ORACLE_ADMIN_USER:-$ORACLE_USER}" script remote d pub q ctl rc=0 ans remote_c="" log found
    local -a tty_flag=() opts sudo_cmd=(sudo -n)
    ctl="/tmp/.kenzo-cm-$$"
    opts=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -p "$ORACLE_SSH_PORT"
          -o ControlMaster=auto -o "ControlPath=$ctl" -o ControlPersist=120)
    if [ -n "$ORACLE_ADMIN_KEY" ]; then opts+=(-i "$ORACLE_ADMIN_KEY" -o IdentitiesOnly=yes); fi
    if [ -t 0 ]; then tty_flag=(-t); sudo_cmd=(sudo); fi

    if ! ssh -o BatchMode=yes "${opts[@]}" "${admin_user}@${ORACLE_HOST}" true </dev/null >/dev/null 2>&1; then
        # key login failed -> password login, if the user wants it (interactive only)
        if [ -t 0 ]; then
            if [ -z "$ORACLE_PASSWORD_LOGIN" ]; then
                read -r -p "No key login to Oracle. Log in as ${admin_user} with a PASSWORD instead (needs PasswordAuthentication yes on Oracle)? [y/N]: " ans
                case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in y|yes) ORACLE_PASSWORD_LOGIN=yes ;; *) ORACLE_PASSWORD_LOGIN=no ;; esac
            fi
            if [ "$ORACLE_PASSWORD_LOGIN" = yes ]; then
                echo "Logging in to ${admin_user}@${ORACLE_HOST} (ssh asks for the password):"
                ssh -o NumberOfPasswordPrompts=3 "${opts[@]}" "${admin_user}@${ORACLE_HOST}" true || {
                    echo "  Password login failed. Oracle images usually disable it: set 'PasswordAuthentication yes'" >&2
                    echo "  in /etc/ssh/sshd_config (and sshd_config.d/*.conf) on Oracle, reload sshd, then retry." >&2
                    return 1
                }
            else
                return 1
            fi
        else
            return 1
        fi
    fi
    echo "Admin SSH access to Oracle works (${admin_user}@${ORACLE_HOST}) -- configuring the relay over SSH."
    if ! script="$(find_oracle_script)"; then
        echo "  ...but setup_oracle.sh wasn't found next to this script (use --oracle-script PATH). Falling back to the manual step." >&2
        ssh -O exit -o "ControlPath=$ctl" "${admin_user}@${ORACLE_HOST}" >/dev/null 2>&1 || true
        return 1
    fi
    pub="$(cat "${TUNNEL_KEY}.pub")"
    remote="/tmp/setup_oracle_relay.$$.sh"
    ssh "${opts[@]}" "${admin_user}@${ORACLE_HOST}" "cat > $remote && chmod 700 $remote" < "$script" || rc=1
    if [ "$rc" -eq 0 ] && [ -n "$CADDYFILE_LOCAL" ]; then
        remote_c="/tmp/caddy_oracle.$$"
        ssh "${opts[@]}" "${admin_user}@${ORACLE_HOST}" "cat > $remote_c" < "$CADDYFILE_LOCAL" || rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        local -a rargs=(relay --from-phone --tunnel-user "$ORACLE_USER" --authorize-key "$pub")
        if [ -n "$remote_c" ]; then
            rargs+=(--caddyfile "$remote_c")
        else
            rargs+=(--remote-port "$ORACLE_REMOTE_PORT")
            for d in "${ORACLE_DOMAIN_LIST[@]}"; do rargs+=(--domain "$d"); done
        fi
        q="$(printf '%q ' "${rargs[@]}")"
        log="$(mktemp)"
        # -t (interactive) lets sudo ask for the admin password if it isn't passwordless
        set +e
        ssh "${tty_flag[@]}" "${opts[@]}" "${admin_user}@${ORACLE_HOST}" \
            "${sudo_cmd[*]} bash $remote $q; rc=\$?; rm -f $remote $remote_c; exit \$rc" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
        set -e
        # domains Oracle's Caddy ended up serving -> used for the end-to-end check
        found="$(tr -d '\r' < "$log" | sed -n 's/^@@RELAY_DOMAINS@@ *//p' | tail -1)"
        if [ -n "$found" ] && [ "${#ORACLE_DOMAIN_LIST[@]}" -eq 0 ]; then
            read -r -a ORACLE_DOMAIN_LIST <<< "$found"
        fi
        rm -f "$log"
    fi
    ssh -O exit -o "ControlPath=$ctl" "${admin_user}@${ORACLE_HOST}" >/dev/null 2>&1 || true
    return "$rc"
}

print_manual_authorize() {
    local d flags="" pub here_oracle
    pub="$(cat "${TUNNEL_KEY}.pub")"
    for d in "${ORACLE_DOMAIN_LIST[@]}"; do flags+=" --domain ${d}"; done
    here_oracle="$(find_oracle_script || echo setup_oracle.sh)"
    echo
    echo "-----------------------------------------------------------"
    echo " ACTION NEEDED on the Oracle box:"
    echo
    echo " A) (recommended) put the files on Oracle, then run the script there:"
    if [ -n "$CADDYFILE_LOCAL" ]; then
        echo "      scp -P ${ORACLE_SSH_PORT} ${here_oracle} ${CADDYFILE_LOCAL} ${ORACLE_USER}@${ORACLE_HOST}:~/   # from a machine that can log in"
        echo "      # on Oracle -- the two files must sit in the same folder and be named setup_oracle.sh / caddy_oracle:"
        echo "      ./setup_oracle.sh relay --authorize-key '${pub}'"
    else
        echo "      scp -P ${ORACLE_SSH_PORT} ${here_oracle} ${ORACLE_USER}@${ORACLE_HOST}:~/   # from a machine that can log in"
        echo "      ./setup_oracle.sh relay --remote-port ${ORACLE_REMOTE_PORT} --authorize-key '${pub}'${flags}"
    fi
    echo
    echo " B) key only, no script (tunnel-only key: no shell, just this one port; Caddy stays as is):"
    echo "      echo 'command=\"echo tunnel-only\",restrict,port-forwarding,permitlisten=\"127.0.0.1:${ORACLE_REMOTE_PORT}\" ${pub}' >> ~/.ssh/authorized_keys"
    echo "-----------------------------------------------------------"
    echo
}

wait_for_key() {   # wait_for_key SECONDS ; 0 = key got authorized
    local limit="$1" t=0
    [ "$limit" -gt 0 ] || return 1
    while true; do
        case "$PROBE_ERR" in
            *"Permission denied"*) ;;
            *) echo; echo "  $(explain_probe)"; return 1 ;;
        esac
        if [ "$t" -ge "$limit" ]; then echo; echo "  gave up waiting (${limit}s)."; return 1; fi
        printf '\r  Waiting for the key to be authorized on Oracle... %3ds  (Enter = skip) ' "$t"
        if [ -t 0 ]; then
            if read -r -t 5 _; then echo; return 1; fi
        else
            sleep 5
        fi
        t=$((t + 5))
        if probe_tunnel_key; then echo; return 0; fi
    done
}

verify_oracle_tunnel() {
    local d code
    sleep 5
    if ! systemctl is-active --quiet oracle-tunnel.service; then
        echo "  service: NOT running"
        $SUDO journalctl -u oracle-tunnel.service -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
        return 1
    fi
    if $SUDO journalctl -u oracle-tunnel.service --since "-30s" --no-pager 2>/dev/null | grep -qi "remote port forwarding failed"; then
        echo "  service: running, but Oracle REFUSED the forward on 127.0.0.1:${ORACLE_REMOTE_PORT}:"
        echo "    - port still held by a stale connection? give it ~30s (setup_oracle.sh relay enables keepalive to prevent this)"
        echo "    - key authorized for another port? re-run setup_oracle.sh relay --remote-port ${ORACLE_REMOTE_PORT} --authorize-key '<pub>'"
        echo "    - AllowTcpForwarding=no in Oracle's sshd_config?"
        return 1
    fi
    echo "  service: running -- tunnel up (Oracle 127.0.0.1:${ORACLE_REMOTE_PORT} -> here 127.0.0.1:${ORACLE_LOCAL_PORT})"
    local first=1 tries
    for d in "${ORACLE_DOMAIN_LIST[@]}"; do
        code=000
        tries=1; if [ "$first" -eq 1 ]; then tries=6; first=0; fi   # only the first one waits for certs
        for _ in $(seq "$tries"); do
            code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "https://${d}/" 2>/dev/null)" || true
            if [ "$code" != 000 ] && [ "${code:0:1}" != 5 ]; then break; fi
            sleep 5
        done
        case "$code" in
            000) echo "  https://${d}/ : not reachable yet -- DNS not pointing at Oracle, certificate still being issued, or TCP 80/443 closed in the Oracle Security List" ;;
            5*)  echo "  https://${d}/ : HTTP ${code} -- Oracle answers, but nothing replied through the tunnel. Is something listening on 127.0.0.1:${ORACLE_LOCAL_PORT} here?" ;;
            *)   echo "  https://${d}/ : OK (HTTP ${code})" ;;
        esac
    done
}

setup_oracle_tunnel() {
    local ans d reach=1 key_ok=0 wait_s autossh_bin
    CADDYFILE_LOCAL=""
    echo "=================================================="
    echo " Oracle relay tunnel"
    echo "=================================================="

    # ---- 1. ask only for what flags / .env didn't provide ----
    if [ -z "$ORACLE_HOST" ] && [ -t 0 ]; then
        read -r -p "Oracle VPS public IP or hostname: " ORACLE_HOST
    fi
    if [ -z "$ORACLE_HOST" ]; then
        echo "ERROR: no Oracle host. Pass --oracle-host IP (or set ORACLE_HOST in .env)." >&2
        return 1
    fi
    # Caddyfile next to this script? Then it defines the port and the domains.
    CADDYFILE_LOCAL="$(find_oracle_caddyfile)" || CADDYFILE_LOCAL=""
    if [ -n "$CADDYFILE_LOCAL" ]; then
        local cports
        mapfile -t cports < <(caddyfile_ports "$CADDYFILE_LOCAL")
        if [ "${#cports[@]}" -eq 0 ]; then
            echo "WARNING: no 'reverse_proxy 127.0.0.1:PORT' in ${CADDYFILE_LOCAL}; using port ${ORACLE_REMOTE_PORT}." >&2
        elif [ "$ORACLE_REMOTE_PORT_SET" -eq 0 ]; then
            ORACLE_REMOTE_PORT="${cports[0]}"
        elif [[ " ${cports[*]} " != *" ${ORACLE_REMOTE_PORT} "* ]]; then
            echo "ERROR: ${CADDYFILE_LOCAL} proxies to 127.0.0.1:${cports[*]} but --oracle-remote-port is ${ORACLE_REMOTE_PORT}. Make them match." >&2
            return 1
        fi
        if [ "${#cports[@]}" -gt 1 ]; then
            echo "NOTE: ${CADDYFILE_LOCAL} uses several tunnel ports (${cports[*]}); this device tunnels only ${ORACLE_REMOTE_PORT}." >&2
        fi
        echo "Using ${CADDYFILE_LOCAL} for Oracle's Caddy (domains and tunnel port come from it)."
    fi
    if [ -t 0 ]; then
        if [ "$ORACLE_USER_SET" -eq 0 ]; then
            read -r -p "SSH user on Oracle [${ORACLE_USER}]: " ans
            if [ -n "$ans" ]; then ORACLE_USER="$ans"; fi
        fi
        if [ "${#ORACLE_DOMAIN_LIST[@]}" -eq 0 ] && [ -z "$CADDYFILE_LOCAL" ]; then
            read -r -p "Domain(s) to publish via Oracle, space-separated (blank = I'll configure Caddy there myself): " ans
            if [ -n "$ans" ]; then read -r -a ORACLE_DOMAIN_LIST <<< "${ans//,/ }"; fi
        fi
        if [ -z "$ORACLE_ADMIN_KEY" ] && ! ssh-add -l >/dev/null 2>&1; then
            read -r -p "Key file that can log in to Oracle as admin, for fully automatic setup (blank = password login or authorize by hand): " ORACLE_ADMIN_KEY
        fi
    fi
    ORACLE_ADMIN_KEY="${ORACLE_ADMIN_KEY/#\~/$HOME}"
    if [ -n "$ORACLE_ADMIN_KEY" ] && [ ! -r "$ORACLE_ADMIN_KEY" ]; then
        echo "WARNING: admin key '$ORACLE_ADMIN_KEY' isn't readable -- ignoring it." >&2
        ORACLE_ADMIN_KEY=""
    fi

    # ---- validate ----
    [[ "$ORACLE_HOST" =~ ^[A-Za-z0-9._-]+$ ]]   || { echo "ERROR: invalid Oracle host '$ORACLE_HOST'." >&2; return 1; }
    [[ "$ORACLE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "ERROR: invalid Oracle user '$ORACLE_USER'." >&2; return 1; }
    for d in ORACLE_SSH_PORT ORACLE_LOCAL_PORT ORACLE_REMOTE_PORT; do
        [[ "${!d}" =~ ^[0-9]+$ ]] && [ "${!d}" -ge 1 ] && [ "${!d}" -le 65535 ] \
            || { echo "ERROR: $d must be 1-65535 (got '${!d}')." >&2; return 1; }
    done
    for d in "${ORACLE_DOMAIN_LIST[@]}"; do
        [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$d" == *.* ]] \
            || { echo "ERROR: invalid domain '$d' (plain hostnames only, no port)." >&2; return 1; }
    done

    echo "  here 127.0.0.1:${ORACLE_LOCAL_PORT}  <==  ${ORACLE_USER}@${ORACLE_HOST}:${ORACLE_SSH_PORT} (Oracle 127.0.0.1:${ORACLE_REMOTE_PORT})"
    if [ "${#ORACLE_DOMAIN_LIST[@]}" -gt 0 ]; then echo "  publishing: ${ORACLE_DOMAIN_LIST[*]}"; fi
    echo "  (change with --oracle-user/-ssh-port/-local-port/-remote-port)"

    # ---- preflight ----
    if ! tcp_ok "$ORACLE_HOST" "$ORACLE_SSH_PORT"; then
        echo "WARNING: can't reach ${ORACLE_HOST}:${ORACLE_SSH_PORT} from here (no internet, wrong IP, or TCP ${ORACLE_SSH_PORT} blocked in the Oracle Security List)." >&2
        echo "         Installing the service anyway; it keeps retrying and connects once that's fixed." >&2
        reach=0
    fi
    if ! tcp_ok 127.0.0.1 "$ORACLE_LOCAL_PORT"; then
        echo "NOTE: nothing listens on 127.0.0.1:${ORACLE_LOCAL_PORT} yet. The tunnel still comes up; visitors get a 502 until your proxy/app runs there."
    fi

    # ---- 2. autossh + dedicated key ----
    command -v autossh >/dev/null 2>&1 || apt_install autossh || { echo "ERROR: couldn't install autossh." >&2; return 1; }
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    TUNNEL_KEY="$HOME/.ssh/oracle_tunnel"
    if [ ! -f "$TUNNEL_KEY" ]; then
        ssh-keygen -t ed25519 -f "$TUNNEL_KEY" -N "" -C "oracle-tunnel@$(hostname)" -q
        echo "Generated a dedicated tunnel key: $TUNNEL_KEY"
    else
        echo "Reusing tunnel key: $TUNNEL_KEY"
    fi

    # ---- 3. get the key (and Caddy) onto Oracle ----
    if [ "$reach" -eq 1 ]; then
        if oracle_admin_setup; then echo "Oracle side configured automatically."; fi
        if probe_tunnel_key; then
            key_ok=1
            echo "Tunnel key login to Oracle: OK."
        else
            print_manual_authorize
            if [ -t 0 ]; then wait_s="${ORACLE_WAIT:-300}"; else wait_s="${ORACLE_WAIT:-0}"; fi
            if wait_for_key "$wait_s"; then
                key_ok=1
                echo "Key authorized -- continuing."
            else
                echo "Continuing without confirmation: the service retries every 5s and connects as soon as the key is in."
            fi
        fi
    fi

    # ---- 4. service ----
    autossh_bin="$(command -v autossh)"
    $SUDO tee /etc/systemd/system/oracle-tunnel.service >/dev/null << TUNNELEOF
[Unit]
Description=SSH reverse tunnel to Oracle relay
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=${ME}
Environment=AUTOSSH_GATETIME=0
ExecStart=${autossh_bin} -M 0 -N -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -i ${TUNNEL_KEY} -p ${ORACLE_SSH_PORT} -R 127.0.0.1:${ORACLE_REMOTE_PORT}:127.0.0.1:${ORACLE_LOCAL_PORT} ${ORACLE_USER}@${ORACLE_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
TUNNELEOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable oracle-tunnel.service >/dev/null 2>&1 || true
    $SUDO systemctl restart oracle-tunnel.service || echo "WARNING: couldn't start oracle-tunnel.service." >&2

    # ---- 5. verify ----
    echo "Checking the tunnel..."
    if [ "$key_ok" -eq 1 ]; then
        verify_oracle_tunnel || true
    else
        echo "  (not verified: key not confirmed on Oracle yet)"
    fi
    echo
    echo "Manage:  systemctl status oracle-tunnel   |   journalctl -fu oracle-tunnel"
    echo "Re-run just this part any time:  ./setup_kenzo.sh --tunnel-only"
    return 0
}

ensure_network
clock_bad && APT_OPTS=(-o Acquire::Check-Date=false)

if [ "$TUNNEL_ONLY" -eq 1 ]; then
    if ! command -v autossh >/dev/null 2>&1; then
        apt_update 2>/dev/null || true
        sync_clock
        apt_update 2>/dev/null || true
    fi
    if setup_oracle_tunnel; then exit 0; else exit 1; fi
fi

echo "=================================================="
echo " Package sanity (apt update + optional extras)"
echo "=================================================="

apt_update 2>/dev/null || true
sync_clock
apt_update 2>/dev/null || true

# The build time script installs these packages; if any are missing because the
# build didn't have network or this rootfs is older, install them now as a fallback.
MISSING=()
for t in zsh git curl wget fzf ripgrep fd-find bat ncdu jq tmux htop btop python3 uv node gh; do
    command -v "$t" >/dev/null 2>&1 || MISSING+=("$t")
done
# fdfind and batcat naming quirks
command -v fd >/dev/null 2>&1 || [ -x /usr/bin/fdfind ] || MISSING+=(fd-find)
command -v bat >/dev/null 2>&1 || [ -x /usr/bin/batcat ] || MISSING+=(bat)
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "Some built-in tools missing (${MISSING[*]}); trying to install them..."
    apt_install_best_effort "${MISSING[@]}" || true
fi

# fd / bat links into ~/.local/bin (if they are missing for some reason)
mkdir -p "$HOME/.local/bin"
[ -x /usr/bin/fdfind ] && ln -sf /usr/bin/fdfind "$HOME/.local/bin/fd" 2>/dev/null || true
[ -x /usr/bin/batcat ] && ln -sf /usr/bin/batcat "$HOME/.local/bin/bat" 2>/dev/null || true

export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$PATH"

# ============================================================
# SSH: authorized keys + optional hardening
# ============================================================

echo "=================================================="
echo " SSH"
echo "=================================================="

mkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"
chmod 700 "$HOME/.ssh"; chmod 600 "$HOME/.ssh/authorized_keys"

if [ "$EXTRA_PUBKEY_SET" -eq 0 ] && [ -t 0 ]; then
    echo "To log in with a key from your PC, paste its PUBLIC key (on Windows: type %USERPROFILE%\\.ssh\\id_ed25519.pub;"
    echo "create one with: ssh-keygen -t ed25519)."
    read -r -p "Public key (blank to skip): " EXTRA_PUBKEY
fi
if [ -n "$EXTRA_PUBKEY" ]; then
    if grep -qxF "$EXTRA_PUBKEY" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "Key already authorized."
    else
        echo "$EXTRA_PUBKEY" >> "$HOME/.ssh/authorized_keys"
        echo "Authorized the pasted key for $ME."
    fi
fi

ask_yn SSH_KEYGEN "Also generate an SSH keypair on the device (for logging in elsewhere / backup)?" no
if [ "$SSH_KEYGEN" = yes ]; then
    DEV_KEY="$HOME/.ssh/kenzo_ed25519"
    if [ -f "$DEV_KEY" ]; then
        echo "Keypair already at $DEV_KEY -- keeping it."
    else
        if [ "$PASSPHRASE_SET" -eq 0 ] && [ -t 0 ]; then
            read -r -s -p "Passphrase for the new key (blank = none): " KEY_PASSPHRASE; echo
        fi
        ssh-keygen -t ed25519 -f "$DEV_KEY" -N "$KEY_PASSPHRASE" -C "${ME}@kenzo" -q
        grep -qxF "$(cat "$DEV_KEY.pub")" "$HOME/.ssh/authorized_keys" || cat "$DEV_KEY.pub" >> "$HOME/.ssh/authorized_keys"
        echo "Generated $DEV_KEY (+ .pub, authorized for $ME)."
    fi
fi

HAVE_KEY=0
grep -Eq '^(ssh-|ecdsa-|sk-)' "$HOME/.ssh/authorized_keys" 2>/dev/null && HAVE_KEY=1

ask_yn DISABLE_ROOT_SSH "Disable SSH login as root (use $ME + sudo instead)?" yes
KEY_ONLY_SSH_WANTED="$KEY_ONLY_SSH"
if [ "$HAVE_KEY" -eq 1 ]; then
    ask_yn KEY_ONLY_SSH "Disable SSH password login (key-only)?" no
else
    if [ "$KEY_ONLY_SSH_WANTED" = yes ]; then
        echo "NOTE: no authorized key present -> NOT disabling password login (would lock you out)."
    fi
    KEY_ONLY_SSH=no
fi

HARDEN_FILE=/etc/ssh/sshd_config.d/10-kenzo-hardening.conf
if [ "$DISABLE_ROOT_SSH" = yes ] || [ "$KEY_ONLY_SSH" = yes ]; then
    {
        echo "# written by setup_kenzo.sh"
        [ "$DISABLE_ROOT_SSH" = yes ] && echo "PermitRootLogin no"
        if [ "$KEY_ONLY_SSH" = yes ]; then
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
            echo "PubkeyAuthentication yes"
        fi
    } | $SUDO tee "$HARDEN_FILE" >/dev/null
    if $SUDO sshd -t 2>/dev/null; then
        $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null || true
        echo "SSH hardening applied ($HARDEN_FILE)."
    else
        $SUDO rm -f "$HARDEN_FILE"
        echo "WARNING: sshd rejected the config; hardening NOT applied." >&2
    fi
else
    $SUDO rm -f "$HARDEN_FILE"
fi

# ============================================================
# Tailscale (optionally via your own Headscale)
# ============================================================

TAILSCALE_IP=""
ask_yn INSTALL_TAILSCALE "Install and connect Tailscale?" yes

if [ "$INSTALL_TAILSCALE" = yes ]; then
    if [ ! -c /dev/net/tun ]; then
        $SUDO modprobe tun 2>/dev/null || true
    fi
    if [ ! -c /dev/net/tun ]; then
        echo "WARNING: /dev/net/tun missing (kernel has no CONFIG_TUN?). Skipping Tailscale." >&2
        INSTALL_TAILSCALE=no
    fi
fi

if [ "$INSTALL_TAILSCALE" = yes ]; then
    if [ "$HEADSCALE_URL_SET" -eq 0 ] || [ -z "$TAILSCALE_AUTHKEY" ]; then
        for env_file in "${ENV_LOADED:-}" "${SCRIPT_DIR}/.env" "$PWD/.env" "$HOME/kenzo/.env" "$HOME/host/.env" "$HOME/docker/.env"; do
            [ -n "$env_file" ] && [ -f "$env_file" ] || continue
            if [ "$HEADSCALE_URL_SET" -eq 0 ] && [ -z "$HEADSCALE_URL" ]; then
                D="$(grep -E '^TAILSCALE_DOMAIN=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d "\"'\r" || true)"
                if [ -n "$D" ]; then
                    case "$D" in http://*|https://*) HEADSCALE_URL="$D" ;; *) HEADSCALE_URL="https://$D" ;; esac
                    echo "Read TAILSCALE_DOMAIN from $env_file -> $HEADSCALE_URL"
                fi
            fi
            if [ -z "$TAILSCALE_AUTHKEY" ]; then
                K="$(grep -E '^HEADSCALE_AUTH_KEY=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d "\"'\r" || true)"
                [ -n "$K" ] && { TAILSCALE_AUTHKEY="$K"; echo "Read HEADSCALE_AUTH_KEY from $env_file"; }
            fi
        done
    fi
    if [ "$HEADSCALE_URL_SET" -eq 0 ] && [ -z "$HEADSCALE_URL" ] && [ -t 0 ]; then
        read -r -p "Headscale control server URL (blank = tailscale.com): " HEADSCALE_URL
    fi

    if ! command -v tailscale >/dev/null 2>&1; then
        if ! tcp_ok 1.1.1.1 443; then
            echo "WARNING: no internet, cannot install Tailscale. Re-run setup_kenzo.sh once connectivity is up." >&2
        else
            echo "Installing Tailscale..."
            curl -fsSL https://tailscale.com/install.sh | $SUDO sh || echo "WARNING: Tailscale install failed." >&2
        fi
    fi

    if command -v tailscale >/dev/null 2>&1; then
        $SUDO systemctl enable --now tailscaled 2>/dev/null || true
        READY=0
        for _ in $(seq 1 15); do
            $SUDO tailscale status >/dev/null 2>&1 && { READY=1; break; }
            sleep 1
        done
        if [ "$READY" -eq 1 ]; then
            TS_UP=(tailscale up --hostname="$(hostname -s)")
            [ -n "$HEADSCALE_URL" ]     && TS_UP+=(--login-server="$HEADSCALE_URL")
            [ -n "$TAILSCALE_AUTHKEY" ] && TS_UP+=(--authkey="$TAILSCALE_AUTHKEY")
            echo "Bringing up Tailscale (30s cap; prints a login URL if not yet registered)..."
            set +e; timeout 30 $SUDO "${TS_UP[@]}"; RC=$?; set -e
            [ "$RC" -ne 0 ] && echo "WARNING: 'tailscale up' exited $RC -- run it manually later."
            TAILSCALE_IP="$($SUDO tailscale ip -4 2>/dev/null | head -1)" || true
        else
            echo "WARNING: tailscaled not responding -- check: sudo journalctl -u tailscaled -n 50" >&2
        fi
    fi
fi

# ============================================================
# UFW Firewall
# ============================================================

if [ "$LAN_SUBNET_SET" -eq 0 ] && [ -t 0 ]; then
    read -r -p "Extra LAN subnet to allow SSH from / whitelist, e.g. your Wi-Fi 192.168.1.0/24 (blank = none): " LAN_SUBNET
fi

ask_yn ENABLE_UFW "Enable the UFW firewall?" yes
UFW_ON=no
if [ "$ENABLE_UFW" = yes ]; then
    command -v ufw >/dev/null 2>&1 || apt_install ufw || true
    if command -v ufw >/dev/null 2>&1; then
        # If ip6tables extensions (rt/hl) are missing in running kernel, set IPV6=no in /etc/default/ufw
        if ! $SUDO ip6tables -A INPUT -m rt --rt-type 0 -j DROP 2>/dev/null; then
            $SUDO sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw 2>/dev/null || true
        fi
        $SUDO ufw default deny incoming
        $SUDO ufw default allow outgoing
        $SUDO ufw allow in on usb0
        $SUDO ufw allow in on tailscale0
        # Never lock ourselves out: also allow SSH from the subnet we are connected through right now.
        if [ -z "$LAN_SUBNET" ]; then
            LAN_SUBNET="$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' | while read -r _if; do ip -o -4 route show dev "$_if" scope link 2>/dev/null | awk '{print $1; exit}'; done || true)"
            [ -n "$LAN_SUBNET" ] && echo "Allowing SSH from the current LAN $LAN_SUBNET (override with --lan-subnet)."
        fi
        if [ -n "$LAN_SUBNET" ]; then
            $SUDO ufw allow from "$LAN_SUBNET" to any port 22 proto tcp
            $SUDO ufw allow from "$LAN_SUBNET" to any port 53
        fi
        if $SUDO ufw --force enable; then UFW_ON=yes; else echo "WARNING: ufw failed to enable (kernel netfilter?)." >&2; fi
    else
        echo "WARNING: ufw still not installed." >&2
    fi
fi

# ============================================================
# Cloudflare Tunnel (optional)
# ============================================================

ask_yn INSTALL_CLOUDFLARE "Install Cloudflare Tunnel (cloudflared)?" no
if [ "$INSTALL_CLOUDFLARE" = yes ]; then
    if [ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
        for env_file in "${ENV_LOADED:-}" "${SCRIPT_DIR}/.env" "$PWD/.env" "$HOME/kenzo/.env" "$HOME/host/.env" "$HOME/docker/.env"; do
            [ -n "$env_file" ] && [ -f "$env_file" ] || continue
            T="$(grep -E '^CLOUDFLARE_TUNNEL_TOKEN=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d "\"'\r" || true)"
            [ -n "$T" ] && { CLOUDFLARE_TUNNEL_TOKEN="$T"; echo "Read CLOUDFLARE_TUNNEL_TOKEN from $env_file"; break; }
        done
    fi
    if [ -z "$CLOUDFLARE_TUNNEL_TOKEN" ] && [ -t 0 ]; then
        read -r -p "Cloudflare Tunnel token (blank = skip): " CLOUDFLARE_TUNNEL_TOKEN
    fi
    if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
        if ! command -v cloudflared >/dev/null 2>&1; then
            curl -fL --output /tmp/cloudflared.deb \
                "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${DEB_ARCH}.deb" \
                && $SUDO dpkg -i /tmp/cloudflared.deb || echo "WARNING: cloudflared install failed." >&2
            rm -f /tmp/cloudflared.deb
        fi
        if command -v cloudflared >/dev/null 2>&1; then
            $SUDO cloudflared service uninstall 2>/dev/null || true
            $SUDO cloudflared service install "$CLOUDFLARE_TUNNEL_TOKEN" || true
            $SUDO systemctl enable --now cloudflared || true
        fi
    else
        echo "No token -- skipping cloudflared."
    fi
fi

# ============================================================
# Oracle relay tunnel (see setup_oracle_tunnel above)
# ============================================================

if [ -z "$INSTALL_ORACLE_TUNNEL" ] && [ -n "$ORACLE_HOST" ]; then INSTALL_ORACLE_TUNNEL=yes; fi
ask_yn INSTALL_ORACLE_TUNNEL "Set up the SSH reverse tunnel to your Oracle relay?" no
if [ "$INSTALL_ORACLE_TUNNEL" = yes ]; then
    setup_oracle_tunnel || echo "WARNING: Oracle tunnel setup did not complete -- re-run: ./setup_kenzo.sh --tunnel-only" >&2
fi

# ============================================================
# Docker (optional)
# ============================================================

ask_yn INSTALL_DOCKER "Install and configure Docker on this device?" no
if [ "$INSTALL_DOCKER" = yes ]; then
    echo "Configuring Docker..."
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker not found; installing docker.io and docker-compose-v2..."
        apt_install_best_effort docker.io docker-compose-v2 docker-buildx || true
    fi
    $SUDO getent group docker >/dev/null 2>&1 || $SUDO groupadd docker 2>/dev/null || true
    $SUDO usermod -aG docker "$ME" 2>/dev/null || true
    $SUDO systemctl enable --now docker 2>/dev/null || true
elif [ "$INSTALL_DOCKER" = no ]; then
    echo "Docker skipped. Disabling any running Docker daemon to save RAM and CPU..."
    $SUDO systemctl disable --now docker containerd 2>/dev/null || true
fi

# ============================================================
# Default shell + Git config
# ============================================================

$SUDO usermod -s "$(command -v zsh)" "$ME" 2>/dev/null || $SUDO chsh -s "$(command -v zsh)" "$ME" || echo "WARNING: couldn't change login shell." >&2

echo "Configuring Git..."
git config --global init.defaultBranch    main
git config --global pull.rebase           false
git config --global push.autoSetupRemote  true
if command -v delta >/dev/null 2>&1; then
    git config --global core.pager            delta
    git config --global interactive.diffFilter "delta --color-only"
    git config --global delta.navigate        true
    git config --global delta.light           false
fi
git config --global merge.conflictstyle   diff3
git config --global diff.colorMoved       default

# ============================================================
# Aliases: systemctl & journalctl
# ============================================================

echo "Configuring systemctl and journalctl aliases..."
$SUDO tee /etc/profile.d/systemd-aliases.sh >/dev/null << 'EOF'
# systemctl aliases
alias sc='systemctl'
alias scu='systemctl --user'
alias scs='systemctl status'
alias scstart='sudo systemctl start'
alias scstop='sudo systemctl stop'
alias scr='sudo systemctl restart'
alias sce='sudo systemctl enable'
alias scd='sudo systemctl disable'
alias scdr='sudo systemctl daemon-reload'
alias scfailed='systemctl --failed'

# journalctl aliases
alias jc='journalctl'
alias jcu='journalctl --user'
alias jcf='journalctl -f'
alias jce='journalctl -xe'
alias jcu-f='journalctl --user -f'
alias jcu-xe='journalctl --user -xe'
alias jc-u='journalctl -u'
alias jc-fu='journalctl -f -u'
EOF
$SUDO chmod 644 /etc/profile.d/systemd-aliases.sh

# Ensure non-login interactive shells also load the aliases
for rc in "/etc/bash.bashrc" "/etc/zsh/zshrc" "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && ! grep -q "systemd-aliases.sh" "$rc" 2>/dev/null; then
        echo '[ -r /etc/profile.d/systemd-aliases.sh ] && . /etc/profile.d/systemd-aliases.sh' | $SUDO tee -a "$rc" >/dev/null
    fi
done

# ============================================================
# Summary
# ============================================================

PHONE_IPS="$(hostname -I 2>/dev/null || true)"
echo "=================================================="
echo " Setup complete"
echo "=================================================="
echo "Versions:"
for t in zsh git delta fzf fd rg bat eza zoxide btop ncdu fastfetch uv node bun gh; do
    printf '  %-10s: ' "$t"
    if command -v "$t" >/dev/null 2>&1; then "$t" --version 2>/dev/null | head -1 || echo installed; else echo "not found"; fi
done
if [ "$INSTALL_DOCKER" = yes ]; then
    printf '  %-10s: ' docker
    if command -v docker >/dev/null 2>&1; then docker --version 2>/dev/null | head -1 || echo installed; else echo "not found"; fi
    printf '  %-10s: ' compose; docker compose version 2>/dev/null || echo "not found"
    printf '  %-10s: ' dockerd; $SUDO docker info >/dev/null 2>&1 && echo running || echo "NOT running (sudo systemctl status docker)"
else
    printf '  %-10s: disabled/skipped (conserving resources)\n' docker
fi
[ -f /etc/systemd/system/oracle-tunnel.service ] && { printf '  %-10s: ' tunnel; systemctl is-active oracle-tunnel.service 2>/dev/null || echo inactive; }
echo
echo "Accounts / access:"
echo "  default user : $ME  (login shell: zsh)"
echo "  addresses    : ${PHONE_IPS:-none}"
echo "  tailscale    : ${TAILSCALE_IP:-not connected}"
echo "  firewall     : UFW ${UFW_ON}"
echo "  ssh          : root login $([ "$DISABLE_ROOT_SSH" = yes ] && echo disabled || echo allowed), password login $([ "$KEY_ONLY_SSH" = yes ] && echo disabled || echo allowed)"
echo "  over USB     : ssh ${ME}@192.168.7.2"
echo
if [ "$INSTALL_DOCKER" = yes ]; then
    echo "Helper scripts: ddeploy dockerstart"
    echo "Docker group membership needs a fresh login (log out/in or 'newgrp docker')."
else
    echo "Docker disabled on this host."
fi
echo "Start zsh now with: exec zsh"
