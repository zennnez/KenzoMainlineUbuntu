#!/usr/bin/env bash
# ============================================================
# Oracle VPS setup: dev environment + public relay for the
# reverse tunnel coming from your phone / other devices.
#
#   ./setup_oracle.sh                 dev environment, then offers the relay
#   ./setup_oracle.sh dev             dev environment only
#   ./setup_oracle.sh relay [opts]    relay only: tunnel key + Caddy + firewall
#
# Keep these three files together (on the phone/home side, next to each other):
#   setup_kenzo.sh   setup_oracle.sh   caddy_oracle
# `caddy_oracle` is the Caddyfile for this relay. If it sits next to this script it is
# installed as /etc/caddy/Caddyfile (validated first, the old one backed up), and the
# tunnel port + domains are read from it -- no --domain / --remote-port needed.
#
# Easiest tunnel setup:
#   1. On the phone run
#        ./setup_kenzo.sh --tunnel-only --oracle-host <this box's IP>
#   2. It either configures this box over SSH by itself (when it can log in
#      here) or prints ONE command to paste here, then waits and verifies.
#
# `relay` is safe to re-run: it updates keys and the Caddyfile in place.
# ============================================================

set -euo pipefail

SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

MODE="all"
case "${1:-}" in all|dev|relay) MODE="$1"; shift ;; esac

RELAY_PORT_SET=0; if [ -n "${RELAY_PORT:-}" ]; then RELAY_PORT_SET=1; fi
RELAY_PORT="${RELAY_PORT:-8080}"
CADDYFILE_SRC=""      # path to a Caddyfile to install, "none" = generate from --domain
RELAY_EMAIL="${RELAY_EMAIL:-}"
RELAY_DOMAINS=()
RELAY_KEYS=()
RESTRICT_KEY=yes
TUNNEL_USER=""
RELAY_REQUESTED=0
FROM_PHONE=0

usage() {
    cat << 'USAGEEOF'
Usage: setup_oracle.sh [all|dev|relay] [options]

  all     (default) dev environment, then offers to set up the relay
  dev     dev environment only
  relay   relay only (what the phone's tunnel needs; no dev tooling)

Relay options (any of these in `all` mode also enables the relay):
  --caddyfile PATH|none     Caddyfile to install (default: ./caddy_oracle next to this script,
                            if present). Tunnel port and domains are read from it.
                            `none` = ignore it and generate one from --domain.
  --domain D[:PORT]         Domain to publish via a GENERATED Caddyfile. Repeatable.
                            PORT = tunnel port on this box (default --remote-port)
  --remote-port PORT        127.0.0.1 port the phone's tunnel binds here (default 8080;
                            must match setup_kenzo.sh --oracle-remote-port)
  --authorize-key 'KEY'     Authorize the phone's PUBLIC key (setup_kenzo.sh prints it).
                            Restricted to tunnel-only: no shell, only that port.
  --authorize-key-file F    Same, reading key(s) from a file
  --tunnel-user USER        Account the phone logs in as (default: you / $SUDO_USER)
  --no-restrict-key         Don't add tunnel-only restrictions to the key
  --email ADDR              ACME/Let's Encrypt contact email for Caddy
  -h, --help
USAGEEOF
}

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
    case "$1" in
        --domain)             [ -n "${2:-}" ] || die "--domain needs a value"
                              RELAY_DOMAINS+=("$2"); RELAY_REQUESTED=1; shift 2 ;;
        --remote-port|--relay-port)
                              [ -n "${2:-}" ] || die "$1 needs a value"
                              RELAY_PORT="$2"; RELAY_PORT_SET=1; shift 2 ;;
        --caddyfile)          [ -n "${2:-}" ] || die "--caddyfile needs a value"
                              CADDYFILE_SRC="$2"; RELAY_REQUESTED=1; shift 2 ;;
        --authorize-key)      [ -n "${2:-}" ] || die "--authorize-key needs a value"
                              RELAY_KEYS+=("$2"); RELAY_REQUESTED=1; shift 2 ;;
        --authorize-key-file) [ -r "${2:-}" ] || die "cannot read key file '${2:-}'"
                              while IFS= read -r _l || [ -n "$_l" ]; do
                                  if [[ "$_l" =~ ^(ssh-|ecdsa-) ]]; then RELAY_KEYS+=("$_l"); fi
                              done < "$2"
                              RELAY_REQUESTED=1; shift 2 ;;
        --tunnel-user)        TUNNEL_USER="${2:-}"; shift 2 ;;
        --email)              RELAY_EMAIL="${2:-}"; shift 2 ;;
        --no-restrict-key)    RESTRICT_KEY=no; shift ;;
        --from-phone)         FROM_PHONE=1; shift ;;      # internal: called by setup_kenzo.sh
        -h|--help)            usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ============================================================
# Relay: tunnel key + Caddy + firewall
# ============================================================
# Traffic path:
#   Internet -> this box (public IP, real Let's Encrypt cert via Caddy)
#            -> 127.0.0.1:<remote-port>  (the phone's outbound SSH reverse tunnel)
#            -> the phone's own reverse proxy
# The phone dials OUT, so CGNAT/NAT on its side doesn't matter, and the only
# inbound port the tunnel needs is the SSH port you already use.

is_port()      { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_domain() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$1" == *.* ]]; }

port_listening() {
    ss -tlnH 2>/dev/null | awk -v p=":$1" '{ a=$4; if (substr(a, length(a)-length(p)+1) == p) f=1 } END { exit !f }'
}

public_ip() {
    curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null \
        || curl -4fsS --max-time 6 https://ifconfig.me 2>/dev/null || true
}

authorize_tunnel_keys() {   # uses: RELAY_KEYS, RELAY_ALLPORTS, TUNNEL_USER, T_HOME, T_GRP
    local ak="$T_HOME/.ssh/authorized_keys" key blob label opts line tmp p
    echo "--- Authorizing tunnel key(s) for ${TUNNEL_USER}"
    $SUDO install -d -m 700 -o "$TUNNEL_USER" -g "$T_GRP" "$T_HOME/.ssh"
    $SUDO touch "$ak"
    $SUDO chown "$TUNNEL_USER:$T_GRP" "$ak"
    $SUDO chmod 600 "$ak"

    # tunnel-only: forced no-op command (no shell), port-forwarding limited to our ports
    opts='command="echo tunnel-only",restrict,port-forwarding'
    for p in "${RELAY_ALLPORTS[@]}"; do opts+=",permitlisten=\"127.0.0.1:${p}\""; done

    for key in "${RELAY_KEYS[@]}"; do
        [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] \
            || die "That doesn't look like an SSH public key: ${key:0:40}..."
        blob="$(awk '{print $2}' <<<"$key")"
        label="$(awk '{print ($3=="" ? "key" : $3)}' <<<"$key")"
        tmp="$(mktemp)"
        $SUDO grep -vF "$blob" "$ak" > "$tmp" || true      # re-running replaces the old line
        if [ "$RESTRICT_KEY" = yes ]; then line="${opts} ${key}"; else line="$key"; fi
        printf '%s\n' "$line" >> "$tmp"
        $SUDO install -m 600 -o "$TUNNEL_USER" -g "$T_GRP" "$tmp" "$ak"
        rm -f "$tmp"
        if [ "$RESTRICT_KEY" = yes ]; then
            echo "    authorized ${label} (tunnel-only, may bind 127.0.0.1:${RELAY_ALLPORTS[*]})"
        else
            echo "    authorized ${label} (unrestricted)"
        fi
    done
}

tune_sshd() {
    local f=/etc/ssh/sshd_config.d/20-relay-keepalive.conf fwd
    # Without this a dropped phone connection can keep the remote port bound for
    # hours, and the reconnecting tunnel then fails with "forwarding failed".
    if [ -d /etc/ssh/sshd_config.d ] && [ ! -f "$f" ]; then
        printf '# written by setup_oracle.sh relay\nClientAliveInterval 15\nClientAliveCountMax 2\n' \
            | $SUDO tee "$f" >/dev/null
        if $SUDO sshd -t 2>/dev/null; then
            $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd 2>/dev/null || true
            echo "    sshd: client keepalive on (a dead tunnel frees its port in ~30s)"
        else
            $SUDO rm -f "$f"
            warn "sshd rejected the keepalive drop-in; skipped it."
        fi
    fi
    fwd="$($SUDO sshd -T 2>/dev/null | awk '$1=="allowtcpforwarding"{print $2}')" || true
    case "$fwd" in
        no|local) warn "sshd has AllowTcpForwarding=${fwd}: reverse tunnels will be refused. Set it to 'yes' (or 'remote') in /etc/ssh/sshd_config and reload sshd." ;;
    esac
}

install_caddy() {
    if command -v caddy >/dev/null 2>&1; then
        echo "--- Caddy already installed"
        return 0
    fi
    echo "--- Installing Caddy"
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        debian-keyring debian-archive-keyring apt-transport-https curl gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    $SUDO apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy
}

write_caddyfile() {   # uses: RELAY_NAMES, RELAY_PORTS, RELAY_EMAIL
    local tmp i vlog out=/etc/caddy/Caddyfile
    tmp="$(mktemp)"
    {
        echo "# managed by setup_oracle.sh relay -- re-run it to regenerate"
        if [ -n "$RELAY_EMAIL" ]; then
            printf '{\n    email %s\n}\n\n' "$RELAY_EMAIL"
        fi
        for i in "${!RELAY_NAMES[@]}"; do
            echo "${RELAY_NAMES[$i]} {"
            echo "    reverse_proxy 127.0.0.1:${RELAY_PORTS[$i]} {"
            echo "        lb_try_duration 10s"
            echo "        lb_try_interval 250ms"
            echo "    }"
            echo "}"
            echo
        done
    } > "$tmp"

    vlog="$(mktemp)"
    if ! caddy validate --config "$tmp" --adapter caddyfile >"$vlog" 2>&1; then
        grep -v '"level":"info"' "$vlog" >&2 || true
        rm -f "$tmp" "$vlog"
        die "Generated Caddyfile didn't validate (see above)."
    fi
    rm -f "$vlog"
    if [ -f "$out" ] && ! grep -q "managed by setup_oracle.sh" "$out"; then
        $SUDO cp "$out" "${out}.bak.$(date +%s)"
        echo "--- Existing Caddyfile backed up to ${out}.bak.*"
    fi
    $SUDO install -d /etc/caddy
    $SUDO install -m 644 "$tmp" "$out"
    rm -f "$tmp"
    reload_caddy
}

reload_caddy() {
    $SUDO systemctl enable caddy >/dev/null 2>&1 || true
    $SUDO systemctl reload caddy 2>/dev/null || $SUDO systemctl restart caddy
    sleep 1
    if systemctl is-active --quiet caddy; then
        echo "--- Caddy is running"
    else
        warn "Caddy is not active -- check: sudo journalctl -u caddy -n 50"
    fi
}

# ---- using a ready-made Caddyfile (caddy_oracle) ----

find_caddy_file() {   # prints the path; returns 1 if none / disabled
    local c d
    if [ "$CADDYFILE_SRC" = none ]; then return 1; fi
    if [ -n "$CADDYFILE_SRC" ]; then
        [ -r "$CADDYFILE_SRC" ] || die "cannot read --caddyfile '$CADDYFILE_SRC'"
        echo "$CADDYFILE_SRC"; return 0
    fi
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || d=""
    for c in "$d/caddy_oracle" "$PWD/caddy_oracle"; do
        if [ -r "$c" ]; then echo "$c"; return 0; fi
    done
    return 1
}

caddy_file_ports() {   # local ports the file proxies to (comments ignored)
    sed 's/#.*//' "$1" | grep -oE 'reverse_proxy[[:space:]]+127\.0\.0\.1:[0-9]+' | grep -oE '[0-9]+$' | sort -un || true
}

extract_hosts() {      # hostnames of an adapted (JSON) Caddy config
    python3 -c '
import json, sys
out = set()
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "host" and isinstance(v, list):
                out.update(x for x in v if isinstance(x, str))
            else:
                walk(v)
    elif isinstance(o, list):
        for x in o:
            walk(x)
walk(json.load(open(sys.argv[1])))
print(" ".join(sorted(out)))
' "$1"
}

install_caddy_file() {   # install_caddy_file SRC ; sets RELAY_NAMES
    local src="$1" out=/etc/caddy/Caddyfile json hosts="" vlog
    echo "--- Using ${src} as the Caddyfile"
    vlog="$(mktemp)"
    if ! caddy validate --config "$src" --adapter caddyfile >"$vlog" 2>&1; then
        grep -v '"level":"info"' "$vlog" >&2 || true
        rm -f "$vlog"
        die "${src} didn't validate (see above). Nothing was changed."
    fi
    rm -f "$vlog"
    if command -v python3 >/dev/null 2>&1; then
        json="$(mktemp)"
        if caddy adapt --config "$src" --adapter caddyfile >"$json" 2>/dev/null; then
            hosts="$(extract_hosts "$json" 2>/dev/null)" || hosts=""
        fi
        rm -f "$json"
    fi
    read -r -a RELAY_NAMES <<< "$hosts"

    if [ -f "$out" ] && cmp -s "$src" "$out"; then
        echo "--- /etc/caddy/Caddyfile already matches -- left as is"
    else
        if [ -f "$out" ]; then
            $SUDO cp "$out" "${out}.bak.$(date +%s)"
            echo "--- Previous Caddyfile saved as ${out}.bak.*"
        fi
        $SUDO install -d /etc/caddy
        $SUDO install -m 644 "$src" "$out"
    fi
    reload_caddy
    if [ "${#RELAY_NAMES[@]}" -gt 0 ]; then echo "    serving: ${RELAY_NAMES[*]}"; fi
}

open_web_ports() {
    local p pos policy changed=0
    echo "--- Opening 80/443 in the OS firewall"
    if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
        $SUDO ufw allow 80/tcp >/dev/null
        $SUDO ufw allow 443/tcp >/dev/null
        echo "    ufw: allowed 80/tcp, 443/tcp"
        return 0
    fi
    if command -v iptables >/dev/null 2>&1 && $SUDO iptables -S INPUT >/dev/null 2>&1; then
        # Oracle's Ubuntu images ship an INPUT chain that ends in REJECT, so rules must go BEFORE it.
        for p in 80 443; do
            if ! $SUDO iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
                pos="$($SUDO iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')"
                policy="$($SUDO iptables -S INPUT | awk '$1=="-P"{print $3; exit}')"
                if [ -n "$pos" ]; then
                    $SUDO iptables -I INPUT "$pos" -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT
                    changed=1
                elif [ "$policy" = DROP ]; then
                    $SUDO iptables -I INPUT 1 -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT
                    changed=1
                fi
            fi
        done
        if [ "$changed" -eq 1 ]; then
            if command -v netfilter-persistent >/dev/null 2>&1; then
                $SUDO netfilter-persistent save >/dev/null 2>&1 && echo "    iptables: opened 80/443 and saved (netfilter-persistent)"
            elif [ -f /etc/iptables/rules.v4 ]; then
                $SUDO iptables-save | $SUDO tee /etc/iptables/rules.v4 >/dev/null
                echo "    iptables: opened 80/443 and saved to /etc/iptables/rules.v4"
            else
                warn "iptables: opened 80/443 but couldn't persist (install iptables-persistent), they vanish on reboot."
            fi
        else
            echo "    iptables: nothing to change (80/443 already reachable)"
        fi
    else
        echo "    no active ufw/iptables rules found -- nothing to open."
    fi
}

check_dns() {   # uses: RELAY_NAMES, PUBIP
    local d ips
    [ -n "${PUBIP:-}" ] || { warn "couldn't detect this box's public IP; skipping DNS check."; return 0; }
    echo "--- DNS check (this box's public IP: ${PUBIP})"
    for d in "${RELAY_NAMES[@]}"; do
        ips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')" || true
        if [ -z "$ips" ]; then
            warn "${d}: no A record yet -> add one pointing at ${PUBIP} (Caddy can't get a certificate until it resolves)."
        elif [[ " $ips " == *" $PUBIP "* ]]; then
            echo "    ${d}: OK"
        else
            warn "${d}: resolves to ${ips}-- not ${PUBIP}. Fine if it's proxied through Cloudflare; otherwise fix the A record."
        fi
    done
}

setup_relay() {
    local e d p i CF="" doms flags
    is_port "$RELAY_PORT" || die "Invalid --remote-port '$RELAY_PORT'"

    CF="$(find_caddy_file)" || CF=""
    if [ -n "$CF" ] && [ "${#RELAY_DOMAINS[@]}" -gt 0 ]; then
        die "Use either --domain or a Caddyfile (${CF}), not both. Pass --caddyfile none to use --domain."
    fi

    # Nothing given on the command line and no Caddyfile? Ask (interactive only).
    if [ -z "$CF" ] && [ "${#RELAY_DOMAINS[@]}" -eq 0 ] && [ "${#RELAY_KEYS[@]}" -eq 0 ]; then
        [ -t 0 ] || die "relay mode needs caddy_oracle next to this script, or --domain / --authorize-key (see --help)."
        echo "Domain(s) to publish through this relay (D or D:PORT; blank line to finish)."
        while true; do
            read -r -p "  Domain: " e
            [ -z "$e" ] && break
            RELAY_DOMAINS+=("$e")
        done
        read -r -p "Paste the phone's tunnel PUBLIC key (blank = authorize later): " e
        if [ -n "$e" ]; then RELAY_KEYS+=("$e"); fi
    fi

    RELAY_NAMES=(); RELAY_PORTS=(); RELAY_ALLPORTS=()
    if [ -n "$CF" ]; then
        mapfile -t RELAY_ALLPORTS < <(caddy_file_ports "$CF")
        if [ "${#RELAY_ALLPORTS[@]}" -eq 0 ]; then
            warn "no 'reverse_proxy 127.0.0.1:PORT' found in ${CF}; using tunnel port ${RELAY_PORT}."
            RELAY_ALLPORTS=("$RELAY_PORT")
        elif [ "$RELAY_PORT_SET" -eq 1 ] && [[ " ${RELAY_ALLPORTS[*]} " != *" ${RELAY_PORT} "* ]]; then
            die "${CF} proxies to 127.0.0.1:${RELAY_ALLPORTS[*]} but --remote-port is ${RELAY_PORT}. Make them match."
        fi
    else
        for e in "${RELAY_DOMAINS[@]}"; do
            d="${e%%:*}"; p="$RELAY_PORT"
            if [[ "$e" == *:* ]]; then p="${e##*:}"; fi
            valid_domain "$d" || die "Invalid domain '$d'"
            is_port "$p"      || die "Invalid port '$p' for $d"
            RELAY_NAMES+=("$d"); RELAY_PORTS+=("$p")
        done
        if [ "${#RELAY_PORTS[@]}" -gt 0 ]; then
            mapfile -t RELAY_ALLPORTS < <(printf '%s\n' "${RELAY_PORTS[@]}" | sort -un)
        else
            RELAY_ALLPORTS=("$RELAY_PORT")
        fi
    fi

    TUNNEL_USER="${TUNNEL_USER:-${SUDO_USER:-$(id -un)}}"
    id "$TUNNEL_USER" >/dev/null 2>&1 || die "No such user '$TUNNEL_USER' on this box."
    T_HOME="$(getent passwd "$TUNNEL_USER" | cut -d: -f6)"
    T_GRP="$(id -gn "$TUNNEL_USER")"

    echo "=================================================="
    echo " Oracle relay setup"
    echo "=================================================="

    if [ "${#RELAY_KEYS[@]}" -gt 0 ]; then
        authorize_tunnel_keys
        tune_sshd
    fi

    PUBIP=""
    if [ -n "$CF" ] || [ "${#RELAY_NAMES[@]}" -gt 0 ]; then
        $SUDO apt-get update -qq || true
        install_caddy
        if [ -n "$CF" ]; then install_caddy_file "$CF"; else write_caddyfile; fi
        open_web_ports
        PUBIP="$(public_ip)"
        check_dns
    else
        PUBIP="$(public_ip)"
    fi

    echo
    echo "-----------------------------------------------------------"
    echo " Relay status"
    if [ "$FROM_PHONE" -eq 0 ]; then
        for p in "${RELAY_ALLPORTS[@]}"; do
            if port_listening "$p"; then
                echo "   tunnel port 127.0.0.1:${p}: CONNECTED (a device is attached)"
            else
                echo "   tunnel port 127.0.0.1:${p}: waiting for the device to connect"
            fi
        done
    else
        echo "   Oracle side ready for ${TUNNEL_USER}@this-box on 127.0.0.1:${RELAY_ALLPORTS[*]}"
    fi
    echo
    echo " Still needed that no script on this box can do:"
    echo "   * Oracle Cloud Console -> Networking -> VCN -> Security List (or NSG):"
    echo "     add ingress rules for TCP 80 and TCP 443 from 0.0.0.0/0"
    echo "     (and TCP ${SSH_PORT_HINT:-22} for SSH if it isn't open already)."
    echo "   * DNS: every relayed domain -> ${PUBIP:-<this-box-public-IP>}"
    if [ "$FROM_PHONE" -eq 0 ]; then
        echo
        echo " Next, on the phone (with setup_kenzo.sh, setup_oracle.sh and caddy_oracle together):"
        if [ -n "$CF" ]; then
            doms="$(IFS=,; echo "${RELAY_NAMES[*]:-}")"
            echo "   ./setup_kenzo.sh --tunnel-only --oracle-host ${PUBIP:-<this-box-ip>} --oracle-user ${TUNNEL_USER}${doms:+ --oracle-domain $doms}"
        else
            for p in "${RELAY_ALLPORTS[@]}"; do
                flags=""
                for i in "${!RELAY_NAMES[@]}"; do
                    if [ "${RELAY_PORTS[$i]}" = "$p" ]; then flags+=" --oracle-domain ${RELAY_NAMES[$i]}"; fi
                done
                echo "   ./setup_kenzo.sh --tunnel-only --oracle-host ${PUBIP:-<this-box-ip>} --oracle-user ${TUNNEL_USER} --oracle-remote-port ${p}${flags}"
            done
        fi
    fi
    echo "-----------------------------------------------------------"
    echo
    # machine-readable line for setup_kenzo.sh (used for its end-to-end check)
    echo "@@RELAY_DOMAINS@@ ${RELAY_NAMES[*]:-}"
}

if [ "$MODE" = relay ]; then
    setup_relay
    exit 0
fi


echo "=================================================="
echo " Installing packages"
echo "=================================================="

sudo apt update

sudo apt install -y \
    zsh git curl wget unzip zip tar tmux htop btop \
    fzf ripgrep fd-find bat ncdu jq tree \
    build-essential python3 python3-pip python3-venv \
    ca-certificates gnupg lsb-release

# ============================================================
# eza
# ============================================================

if ! command -v eza >/dev/null 2>&1; then
    echo "=================================================="
    echo " Installing eza"
    echo "=================================================="

    sudo mkdir -p /etc/apt/keyrings

    wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
        | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg

    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
        | sudo tee /etc/apt/sources.list.d/gierens.list

    sudo chmod 644 /etc/apt/keyrings/gierens.gpg
    sudo apt update
    sudo apt install -y eza
fi

# ============================================================
# zoxide
# ============================================================

if ! command -v zoxide >/dev/null 2>&1; then
    echo "=================================================="
    echo " Installing zoxide"
    echo "=================================================="

    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
fi

# ============================================================
# Oh My Zsh
# ============================================================

if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "=================================================="
    echo " Installing Oh My Zsh"
    echo "=================================================="

    RUNZSH=no CHSH=no sh -c \
      "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# ============================================================
# Plugins
# ============================================================

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

mkdir -p "$ZSH_CUSTOM/plugins"

clone_if_missing() {
    [ -d "$2" ] || git clone "$1" "$2"
}

clone_if_missing https://github.com/zsh-users/zsh-autosuggestions \
    "$ZSH_CUSTOM/plugins/zsh-autosuggestions"

clone_if_missing https://github.com/zsh-users/zsh-syntax-highlighting \
    "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"

clone_if_missing https://github.com/zsh-users/zsh-completions \
    "$ZSH_CUSTOM/plugins/zsh-completions"

# ============================================================
# fd / bat aliases
# ============================================================

mkdir -p "$HOME/.local/bin"

[ ! -f "$HOME/.local/bin/fd" ] && ln -sf /usr/bin/fdfind "$HOME/.local/bin/fd"
[ ! -f "$HOME/.local/bin/bat" ] && ln -sf /usr/bin/batcat "$HOME/.local/bin/bat"

# ============================================================
# BIN scripts
# ============================================================

mkdir -p "$HOME/bin"

# ddeploy
cat > "$HOME/bin/ddeploy" << 'EOF'
#!/usr/bin/env bash
set -e
cd ~/docker
echo "[+] Pulling latest..."
git pull
echo "[+] Updating submodules..."
git submodule sync --recursive
git submodule update --init --recursive
echo "[+] Rebuilding containers..."
docker compose build
echo "[+] Restarting stack..."
docker compose up -d
echo "[+] Done."
EOF
chmod +x "$HOME/bin/ddeploy"

# ============================================================
# ZSHRC
# ============================================================

[ -f "$HOME/.zshrc" ] && cp "$HOME/.zshrc" "$HOME/.zshrc.bak.$(date +%s)" || true
cat > "$HOME/.zshrc" << 'EOF'
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

plugins=(
    git docker python node npm fzf
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
)

source "$ZSH/oh-my-zsh.sh"

# ============================================================
# PATH
# ============================================================

export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

# ============================================================
# CORE MODERN CLI
# ============================================================

alias ls='eza --icons --group-directories-first'
alias ll='eza -la --icons --git --group-directories-first'
alias la='eza -la --icons --git'
alias lt='eza --tree --icons --level=2'
alias tree='eza --tree --icons'

alias cat='bat --paging=never'
alias less='bat --paging=always'

alias find='fd'
alias grep='rg'
alias top='btop'
alias du='ncdu --color dark'
alias df='df -h'

# ============================================================
# HISTORY INTELLIGENCE (TERMIUS-LIKE)
# ============================================================

setopt SHARE_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt INC_APPEND_HISTORY

HISTSIZE=50000
SAVEHIST=50000

# ============================================================
# GIT
# ============================================================

alias gs='git status -sb'
alias ga='git add'
alias gaa='git add -A'
alias gc='git commit -m'
alias gca='git commit --amend --no-edit'
alias gpl='git pull'
alias gps='git push'
alias gpf='git push --force-with-lease'
alias gl='git pull --rebase'
alias gd='git diff'
alias gds='git diff --staged'
alias gb='git branch -vv'
alias gco='git checkout'
alias gsw='git switch'
alias glog='git log --oneline --graph --decorate --all'
alias gloga='git log --graph --oneline --decorate --all --color'
alias gst='git stash'
alias gstp='git stash pop'

# ============================================================
# SUBMODULES
# ============================================================

alias gsub='git submodule sync --recursive && git submodule update --init --recursive'
alias gsubr='git submodule sync --recursive && git submodule update --init --recursive --remote'

# ============================================================
# DOCKER
# ============================================================

alias dc='docker compose'
alias dcu='docker compose up -d'
alias dcub='docker compose up -d --build'
alias dcd='docker compose down'
alias dcr='docker compose restart'
alias dcl='docker compose logs -f'
alias dclf='docker compose logs -f --tail=100'

alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dpsa='docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'

alias di='docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"'

alias dprune='docker system prune -f'
alias dclean='docker system prune -af --volumes'
alias dsize='docker system df'

# ============================================================
# Python
# ============================================================

alias py='python3'
alias pip='pip3'
alias venv='python3 -m venv'
alias activate='source venv/bin/activate'

# ============================================================
# Docker shortcuts
# ============================================================

alias ddir='cd ~/docker'

# ============================================================
# tmux
# ============================================================

alias t='tmux'
alias ta='tmux attach -t'
alias tls='tmux ls'

# ============================================================
# FZF
# ============================================================
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git --exclude node_modules --exclude .venv --exclude __pycache__'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git --exclude node_modules --exclude .venv'

export FZF_DEFAULT_OPTS='
--height=40%
--layout=reverse
--border
--preview "bat --color=always {} 2>/dev/null || cat {}"
'

# CTRL-R HISTORY SEARCH
export FZF_CTRL_R_OPTS="
--preview 'echo {}'
--preview-window=up:3:hidden:wrap
"

# ============================================================
# ZOXIDE (SMART CD)
# ============================================================

eval "$(zoxide init zsh --cmd cd)"

# ============================================================
# STARTUP FEEL (OPTIONAL)
# ============================================================

if command -v fastfetch >/dev/null 2>&1; then
    [[ $- == *i* ]] && fastfetch
fi
EOF

# ============================================================
# tmux config
# ============================================================

cat > "$HOME/.tmux.conf" << 'EOF'
set -g mouse on
set -g history-limit 50000
set -g status-bg black
set -g status-fg white
EOF

# ============================================================
# fastfetch
# ============================================================

if ! command -v fastfetch >/dev/null 2>&1; then
    echo "Installing fastfetch..."
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64) FF_ARCH="amd64" ;;
        aarch64|arm64) FF_ARCH="aarch64" ;;
        *) FF_ARCH="" ;;
    esac

    if [ -n "$FF_ARCH" ]; then
        wget -qO /tmp/fastfetch.deb \
            "https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-${FF_ARCH}.deb"
        sudo dpkg -i /tmp/fastfetch.deb
        rm /tmp/fastfetch.deb
    else
        echo "Warning: Unsupported architecture ($ARCH) for fastfetch deb package."
    fi
fi

# ============================================================
# delta
# ============================================================

if ! command -v delta >/dev/null 2>&1; then
    echo "Installing delta..."
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64) DELTA_ARCH="amd64" ;;
        aarch64|arm64) DELTA_ARCH="arm64" ;;
        *) DELTA_ARCH="" ;;
    esac

    if [ -n "$DELTA_ARCH" ]; then
        DELTA_VERSION=$(curl -fsSL https://api.github.com/repos/dandavison/delta/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4)
        curl -fsSL \
            "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/git-delta_${DELTA_VERSION}_${DELTA_ARCH}.deb" \
            -o "$HOME/delta.deb"
        sudo dpkg -i "$HOME/delta.deb"
        rm "$HOME/delta.deb"
        delta --version 2>/dev/null || true
    else
        echo "Warning: Unsupported architecture ($ARCH) for delta deb package."
    fi
fi

# ============================================================
# uv
# ============================================================

if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# ============================================================
# Node 22
# ============================================================

if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
    sudo apt install -y nodejs
fi

# ============================================================
# bun
# ============================================================

if ! command -v bun >/dev/null 2>&1; then
    curl -fsSL https://bun.sh/install | bash
fi

# ============================================================
# GitHub CLI (gh)
# ============================================================

if ! command -v gh >/dev/null 2>&1; then
    echo "=================================================="
    echo " Installing GitHub CLI (gh)"
    echo "=================================================="

    sudo mkdir -p -m 755 /etc/apt/keyrings
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt update
    sudo apt install -y gh
fi

# ============================================================
# DEFAULT SHELL
# ============================================================

sudo chsh -s "$(command -v zsh)" "$(id -un)" || echo "Warning: could not change the login shell (run: chsh -s $(command -v zsh))."

# ============================================================
# Git config
# ============================================================

echo "Configuring Git..."
git config --global init.defaultBranch    main
git config --global pull.rebase           false
git config --global push.autoSetupRemote  true
git config --global core.pager            delta
git config --global interactive.diffFilter "delta --color-only"
git config --global delta.navigate        true
git config --global delta.light           false
git config --global merge.conflictstyle   diff3
git config --global diff.colorMoved       default

echo "=================================================="
echo " Setup complete"
echo "=================================================="
echo "Restart shell or run: exec zsh"
echo

echo "Versions installed:"
echo -n "  zsh       : "; zsh --version 2>/dev/null | head -1 || echo "not found"
echo -n "  git       : "; git --version 2>/dev/null || echo "not found"
echo -n "  delta     : "; delta --version 2>/dev/null || echo "not found"
echo -n "  fzf       : "; fzf --version 2>/dev/null || echo "not found"
echo -n "  fd        : "; fd --version 2>/dev/null || echo "not found"
echo -n "  rg        : "; rg --version 2>/dev/null | head -1 || echo "not found"
echo -n "  bat       : "; bat --version 2>/dev/null || echo "not found"
echo -n "  eza       : "; eza --version 2>/dev/null | head -1 || echo "not found"
echo -n "  zoxide    : "; zoxide --version 2>/dev/null || echo "not found"
echo -n "  btop      : "; btop --version 2>/dev/null | head -1 || echo "not found"
echo -n "  ncdu      : "; ncdu --version 2>/dev/null || echo "not found"
echo -n "  fastfetch : "; fastfetch --version 2>/dev/null || echo "not found"
echo -n "  uv        : "; uv --version 2>/dev/null || echo "not found"
echo -n "  node      : "; node --version 2>/dev/null || echo "not found"
echo -n "  bun       : "; bun --version 2>/dev/null || echo "not found"
echo -n "  gh        : "; gh --version 2>/dev/null | head -1 || echo "not found"
echo -n "  docker    : "; docker --version 2>/dev/null || echo "not found"
echo

echo "Shell features:"
echo "  - Oh My Zsh with autosuggestions, syntax highlighting, completions"
echo "  - Ctrl+R fuzzy history search (fzf)"
echo "  - Smart cd with zoxide"
echo "  - Git diff pager: delta"
echo "  - 50k line history with deduplication"
echo

echo "Helper scripts:"
echo "  ddeploy"
echo

echo "Git aliases: gs ga gaa gc gpl gps gd gb glog gst gsub"
echo "Docker aliases: dc dcu dcub dcd dcr dcl dps di dprune"
echo "=================================================="

# ============================================================
# Relay (tunnel key + Caddy + firewall) -- see `relay` mode / --help
# ============================================================

if [ "$MODE" = all ]; then
    if [ "$RELAY_REQUESTED" -eq 1 ]; then
        setup_relay
    elif [ -t 0 ]; then
        read -r -p "Set this box up as a public relay for a phone/device tunnel (Caddy + tunnel key)? [y/N]: " ans
        case "$ans" in [Yy]*) setup_relay ;; esac
    fi
fi
