#!/usr/bin/env bash
# Ubuntu arm64 rootfs (debootstrap) + kenzo overlay -> out/rootfs.ext4
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/scripts/env.sh" ]] && source "$ROOT/scripts/env.sh"
[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo -E "$0" "$@"
[[ -f "$ROOT/scripts/env.sh" ]] && source "$ROOT/scripts/env.sh"
R="$ROOT/out/rootfs"; SUITE="${SUITE:-resolute}"      # Ubuntu 26.04; use noble for 24.04
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
export TIMEZONE="${TIMEZONE:-UTC}"
# Accounts. Anything not exported is asked for interactively:
#   KENZO_USER (default user name), KENZO_USER_PASSWORD, KENZO_ROOT_PASSWORD (blank = root password locked)
ask_secret() {   # VAR "label" required(1|0)
  local var="$1" label="$2" req="$3" a b
  [[ -n "${!var:-}" ]] && return 0
  if [[ ! -t 0 ]]; then
    [[ "$req" == 1 ]] && { echo "export $var=... (no terminal to ask)" >&2; exit 1; }
    return 0
  fi
  while :; do
    read -rsp "$label$([[ $req == 0 ]] && echo ' (blank = none)'): " a; echo
    if [[ -z "$a" ]]; then [[ "$req" == 0 ]] && return 0; echo "Required." >&2; continue; fi
    read -rsp "Confirm: " b; echo
    [[ "$a" == "$b" ]] && { printf -v "$var" '%s' "$a"; return 0; }
    echo "Didn't match, try again." >&2
  done
}
if [[ -z "${KENZO_USER:-}" ]]; then
  if [[ -t 0 ]]; then read -rp "Default (non-root) username [kenzo]: " KENZO_USER; fi
  KENZO_USER="${KENZO_USER:-kenzo}"
fi
[[ "$KENZO_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$KENZO_USER" != root ]] || { echo "invalid KENZO_USER '$KENZO_USER'" >&2; exit 1; }
ask_secret KENZO_USER_PASSWORD "Password for $KENZO_USER" 1
ask_secret KENZO_ROOT_PASSWORD "Password for root" 0
PASS="${KENZO_ROOT_PASSWORD:-}"
UPASS="$KENZO_USER_PASSWORD"
[[ -d "$R/bin" ]] || debootstrap --arch=arm64 --variant=minbase --components=main,universe "$SUITE" "$R" "$MIRROR"
# docker.io lives in universe; make sure it is enabled even on a rootfs created earlier with main only
if ! grep -rqs universe "$R/etc/apt/sources.list" "$R/etc/apt/sources.list.d/"; then
  echo "deb $MIRROR $SUITE main universe" > "$R/etc/apt/sources.list"
  echo "deb $MIRROR $SUITE-updates main universe" >> "$R/etc/apt/sources.list"
fi
if [[ ! -f "$R/.kenzo-pkgs-done" ]]; then
  chroot "$R" apt-get update
  DOCKER_PKG="docker.io"
  [[ "${SKIP_DOCKER:-false}" == "true" || "${SKIP_DOCKER:-false}" == "1" ]] && DOCKER_PKG=""
  chroot "$R" apt-get install -y --no-install-recommends systemd systemd-sysv udev kmod zstd \
     openssh-server sudo iproute2 iputils-ping network-manager ca-certificates nano \
     $DOCKER_PKG iptables systemd-timesyncd avahi-daemon libnss-mdns tzdata
  # Timezone setup
  if [[ -f "$R/usr/share/zoneinfo/$TIMEZONE" ]]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$R/etc/localtime"
    echo "$TIMEZONE" > "$R/etc/timezone"
    chroot "$R" dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
  fi
  touch "$R/.kenzo-pkgs-done"
fi
# Timesync, mDNS (kenzo.local), and Timezone
if [[ ! -f "$R/.kenzo-timesync-avahi-done" ]]; then
  chroot "$R" apt-get update
  chroot "$R" apt-get install -y --no-install-recommends systemd-timesyncd avahi-daemon libnss-mdns tzdata
  if [[ -f "$R/usr/share/zoneinfo/$TIMEZONE" ]]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$R/etc/localtime"
    echo "$TIMEZONE" > "$R/etc/timezone"
    chroot "$R" dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
  fi
  touch "$R/.kenzo-timesync-avahi-done"
fi
# Wi-Fi / Bluetooth userspace (separate marker so an existing rootfs picks it up on the next run)
if [[ ! -f "$R/.kenzo-wireless-pkgs-done" ]]; then
  chroot "$R" apt-get update
  chroot "$R" apt-get install -y --no-install-recommends wpasupplicant iw rfkill wireless-regdb bluez bluez-tools crda iputils-arping
  touch "$R/.kenzo-wireless-pkgs-done"
fi
# GPU, touch, and hardware userspace
if [[ ! -f "$R/.kenzo-graphics-done" ]]; then
  chroot "$R" apt-get update
  chroot "$R" apt-get install -y --no-install-recommends \
     linux-firmware-qualcomm-graphics libgl1-mesa-dri mesa-vulkan-drivers mesa-utils zstd libinput-tools evtest
  if [[ "${SKIP_BROKEN:-true}" != "true" ]]; then
    echo "==> Installing cellular / modem packages (SKIP_BROKEN=false)..."
    chroot "$R" apt-get install -y --no-install-recommends modemmanager libqmi-utils libmbim-utils usb-modeswitch || true
  else
    echo "==> SKIP_BROKEN=true: skipping non-functional cellular/modem packages (packing working hardware only)"
  fi
  touch "$R/.kenzo-graphics-done"
fi
# Always ensure ModemManager is disabled/masked when SKIP_BROKEN=true
if [[ "${SKIP_BROKEN:-true}" == "true" ]]; then
  chroot "$R" systemctl mask ModemManager.service 2>/dev/null || true
  chroot "$R" systemctl disable ModemManager.service 2>/dev/null || true
fi
# NOTE: a password that is literally "..." (the README placeholder) or contains $ ! ` \ gets mangled by your shell
# unless single-quoted:  export KENZO_ROOT_PASSWORD='MyPass123'
for pw in "$PASS" "$UPASS"; do
  [[ "$pw" == "..." ]] && { echo "a password is still the README placeholder '...'" >&2; exit 1; }
done
if [[ -n "$PASS" ]]; then
  printf 'root:%s\n' "$PASS" | chroot "$R" chpasswd
  grep -q '^root:[^!*]' "$R/etc/shadow" || { echo "root password was NOT set in /etc/shadow" >&2; exit 1; }
else
  chroot "$R" passwd -l root >/dev/null   # no root password: log in as $KENZO_USER and use sudo
fi
# Default user: UID 1000 if free, in sudo (+ docker/video/audio/input/render when those groups exist).
if ! chroot "$R" id -u "$KENZO_USER" >/dev/null 2>&1; then
  UIDARG=(); chroot "$R" getent passwd 1000 >/dev/null 2>&1 || UIDARG=(-u 1000)
  chroot "$R" useradd -m "${UIDARG[@]}" -s /usr/bin/zsh "$KENZO_USER" 2>/dev/null || chroot "$R" useradd -m "${UIDARG[@]}" -s /bin/bash "$KENZO_USER"
fi
chroot "$R" usermod -s /usr/bin/zsh "$KENZO_USER" 2>/dev/null || true
printf '%s:%s\n' "$KENZO_USER" "$UPASS" | chroot "$R" chpasswd
grep -q "^$KENZO_USER:[^!*]" "$R/etc/shadow" || { echo "$KENZO_USER password was NOT set in /etc/shadow" >&2; exit 1; }
for g in sudo docker video audio input render; do
  chroot "$R" getent group "$g" >/dev/null 2>&1 && chroot "$R" usermod -aG "$g" "$KENZO_USER" || true
done
# Optional key login (no password needed): KENZO_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" or a file path
if [[ -n "${KENZO_SSH_PUBKEY:-}" ]]; then
  install -d -m700 "$R/root/.ssh"
  if [[ -f "$KENZO_SSH_PUBKEY" ]]; then cat "$KENZO_SSH_PUBKEY"; else printf '%s\n' "$KENZO_SSH_PUBKEY"; fi > "$R/root/.ssh/authorized_keys"
  chmod 600 "$R/root/.ssh/authorized_keys"
  install -d -m700 "$R/home/$KENZO_USER/.ssh"
  cp "$R/root/.ssh/authorized_keys" "$R/home/$KENZO_USER/.ssh/authorized_keys"
  chmod 600 "$R/home/$KENZO_USER/.ssh/authorized_keys"
  chroot "$R" chown -R "$KENZO_USER:$KENZO_USER" "/home/$KENZO_USER/.ssh"
fi
cp -a "$ROOT/rootfs-overlay/." "$R/"
sed -i 's/^ENABLED=yes/ENABLED=no/' "$R/etc/ufw/ufw.conf" 2>/dev/null || true
chmod 755 "$R/usr/local/sbin/usb-gadget-rndis.sh"
chmod 755 "$R/usr/local/sbin/kenzo-wifi" "$R/usr/local/sbin/kenzo-bt" 2>/dev/null || true
ln -sf ../sbin/kenzo-wifi "$R/usr/local/bin/kenzo-wifi" 2>/dev/null || true
ln -sf ../sbin/kenzo-bt "$R/usr/local/bin/kenzo-bt" 2>/dev/null || true
chmod 755 "$R/usr/local/sbin/kenzo-powerkeyd" 2>/dev/null || true
chmod 755 "$R/usr/local/sbin/kenzo-screen" "$R/usr/local/sbin/kenzo-screen-toggle" 2>/dev/null || true

# Wi-Fi autoconnect (/etc/netplan/50-wifi-init.yaml)
# Permissions MUST be 600 and renderer MUST be NetworkManager to avoid wpa_supplicant lock contention.
install -d -m700 "$R/etc/netplan"
WIFI_CFG="$R/etc/netplan/50-wifi-init.yaml"
WIFI_ENTRIES=()

if [[ -n "${KENZO_WIFI_NETWORKS:-}" || -n "${KENZO_WIFI_SSID:-}" ]]; then
  python3 - << 'PYEOF' "$WIFI_CFG"
import json, os, sys, re, yaml

cfg_file = sys.argv[1]
raw_networks = os.environ.get("KENZO_WIFI_NETWORKS", "").strip()
legacy_ssid = os.environ.get("KENZO_WIFI_SSID", "").strip()
legacy_pass = os.environ.get("KENZO_WIFI_PASSWORD", "").strip()

nets = {}
if raw_networks:
    if raw_networks.startswith("{") and raw_networks.endswith("}"):
        try:
            nets = json.loads(raw_networks)
        except Exception:
            pass
    if not nets:
        for item in re.split(r'[\r\n,;]+', raw_networks):
            item = item.strip()
            if not item: continue
            if ":" in item:
                k, v = item.split(":", 1)
            elif "=" in item:
                k, v = item.split("=", 1)
            else:
                k, v = item, ""
            nets[k.strip()] = v.strip()
elif legacy_ssid:
    for s in legacy_ssid.split(","):
        s = s.strip()
        if s:
            nets[s] = legacy_pass

if nets:
    access_points = {}
    for ssid, pw in nets.items():
        if pw:
            access_points[str(ssid)] = {"password": str(pw)}
        else:
            access_points[str(ssid)] = {}

    netplan_data = {
        "network": {
            "version": 2,
            "renderer": "NetworkManager",
            "wifis": {
                "wlan0": {
                    "optional": True,
                    "access-points": access_points,
                    "dhcp4": True
                }
            }
        }
    }
    with open(cfg_file, "w") as f:
        yaml.dump(netplan_data, f, default_flow_style=False)
    os.chmod(cfg_file, 0o600)
    print(f"==> Written {len(nets)} Wi-Fi network(s) to {cfg_file}")
PYEOF
elif [[ -t 0 && ! -f "$WIFI_CFG" ]]; then
  HOST_PROFS=()
  if command -v powershell.exe >/dev/null 2>&1; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && HOST_PROFS+=("$p")
    done < <(powershell.exe -NoProfile -Command 'netsh wlan show profiles' 2>/dev/null | sed -n 's/.*All User Profile.*: *//p' | tr -d '\r')
  fi

  echo "==> Wi-Fi autoconnect setup (/etc/netplan/50-wifi-init.yaml)"
  if [[ ${#HOST_PROFS[@]} -gt 0 ]]; then
    echo "  Discovered host Wi-Fi profiles:"
    for idx in "${!HOST_PROFS[@]}"; do
      printf "    [%d] %s\n" "$((idx+1))" "${HOST_PROFS[$idx]}"
    done
  fi

  while :; do
    read -rp "Select profile number or enter Wi-Fi SSID (blank to skip/done): " sel
    [[ -z "$sel" ]] && break
    chosen_ssid=""
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#HOST_PROFS[@]} )); then
      chosen_ssid="${HOST_PROFS[$((sel-1))]}"
    else
      chosen_ssid="$sel"
    fi

    saved_pw=""
    if command -v powershell.exe >/dev/null 2>&1; then
      saved_pw="$(powershell.exe -NoProfile -Command "netsh wlan show profile name=\"$chosen_ssid\" key=clear" 2>/dev/null | grep -i 'Key Content' | sed 's/.*: //' | tr -d '\r')"
    fi

    if [[ -n "$saved_pw" ]]; then
      read -rsp "Password for '$chosen_ssid' [press Enter to use Windows saved key]: " chosen_pw; echo
      chosen_pw="${chosen_pw:-$saved_pw}"
    else
      read -rsp "Password for '$chosen_ssid': " chosen_pw; echo
    fi

    WIFI_ENTRIES+=("$chosen_ssid:$chosen_pw")
    read -rp "Add another Wi-Fi network? [y/N]: " more_wifi
    [[ "$more_wifi" =~ ^[Yy]$ ]] || break
  done
fi

if [[ ${#WIFI_ENTRIES[@]} -gt 0 ]]; then
  {
    echo "network:"
    echo "  version: 2"
    echo "  renderer: NetworkManager"
    echo "  wifis:"
    echo "    wlan0:"
    echo "      optional: true"
    echo "      access-points:"
    for entry in "${WIFI_ENTRIES[@]}"; do
      s="${entry%%:*}"
      p="${entry#*:}"
      s_esc="${s//\\/\\\\}"; s_esc="${s_esc//\"/\\\"}"
      p_esc="${p//\\/\\\\}"; p_esc="${p_esc//\"/\\\"}"
      printf '        "%s":\n' "$s_esc"
      printf '          password: "%s"\n' "$p_esc"
    done
    echo "      dhcp4: true"
  } > "$WIFI_CFG"
  echo "==> Written Wi-Fi autoconnect configuration to $WIFI_CFG"
fi

# System root directories and overlay files must be owned by root:root (0:0), NOT the host build user!
chown 0:0 "$R"
chown -R 0:0 "$R/etc" "$R/usr" "$R/var" "$R/bin" "$R/sbin" "$R/lib" "$R/root" 2>/dev/null || true
chmod 4755 "$R/usr/bin/sudo.ws" "$R/usr/bin/su" 2>/dev/null || true
chmod 440 "$R/etc/sudoers.d/"* 2>/dev/null || true
chmod 755 "$R/usr/local/bin/"* "$R/usr/local/sbin/"* 2>/dev/null || true
chmod 755 "$R/etc/NetworkManager/dispatcher.d/"* 2>/dev/null || true
chown -R "$KENZO_USER:$KENZO_USER" "$R/home/$KENZO_USER" 2>/dev/null || true

# Ensure netplan permissions are strictly 600 (netplan warns and may fail if open to others)
chmod 600 "$R/etc/netplan/"*.yaml 2>/dev/null || true
chown -R 0:0 "$R/etc/netplan" 2>/dev/null || true


# Substitute the build-time username into the getty auto-login drop-in so
# tty1 auto-logs in as $KENZO_USER instead of staying at a login: prompt.
AUTOLOGIN_DROPIN="$R/etc/systemd/system/getty@tty1.service.d/autologin.conf"
if [[ -f "$AUTOLOGIN_DROPIN" ]]; then
  sed -i -E "s|--autologin [a-zA-Z0-9_-]+|--autologin ${KENZO_USER}|g" "$AUTOLOGIN_DROPIN"
fi
# PAM: tty1 passwordless auto-login for $KENZO_USER.
#
# agetty --autologin $KENZO_USER already skips the `login:` prompt and hands
# /bin/login the user pre-selected, but on Ubuntu 26.04 the /etc/pam.d/login
# stack STILL asks for a password because pam_unix.so always prompts unless a
# preceeding sufficient rule grants access for this specific user+tty combo.
#
# Prepend a tight, scoped `auth sufficient pam_succeed_if.so …` rule as the
# FIRST auth line. Use `quiet` so it doesn't log an approval on every boot.
# Idempotent: if the marker comment is already present (rebuild), skip.
PAM_MARKER="# kenzo-build-rootfs: tty1 passwordless autologin for $KENZO_USER"
PAM_FILE="$R/etc/pam.d/login"
if [[ -f "$PAM_FILE" ]] && ! grep -qF "$PAM_MARKER" "$PAM_FILE" 2>/dev/null; then
  PAM_RULE="${PAM_MARKER}
auth [success=done default=ignore] pam_succeed_if.so quiet tty = /dev/tty1 user = ${KENZO_USER}
"
  # Insert at the very TOP, before any existing `@include common-auth` / `auth` lines.
  # We save old content, overwrite, then append.
  OLD_PAM="$(cat "$PAM_FILE")"
  { printf '%s\n' "$PAM_RULE"; printf '%s\n' "$OLD_PAM"; } > "$PAM_FILE"
  echo "==> PAM tty1 autologin rule injected for user '$KENZO_USER'"
fi
# Wi-Fi/BT firmware you extracted on the host (optional; or run `sudo kenzo-wifi firmware` on the phone). Layout = /usr/lib/firmware.
# NOTE: /lib is a symlink to usr/lib on Ubuntu 26.04, so firmware must live under usr/lib/firmware in the overlay, never lib/firmware.
if [[ -d "$ROOT/firmware" ]]; then
  install -d "$R/usr/lib/firmware"
  for f in "$ROOT/firmware/"*; do
    [[ -e "$f" ]] || continue
    bn="$(basename "$f")"
    if [[ "${DISABLE_ADSP:-${SKIP_BROKEN:-true}}" == "true" ]] && [[ "$bn" == adsp.* ]]; then
      continue
    fi
    cp -a "$f" "$R/usr/lib/firmware/" 2>/dev/null || true
  done
fi
# on-device setup script (passwords, SSH keys, Tailscale, Wi-Fi-based config, ...).
# Packages and non-interactive global config are done AT BUILD TIME below via setup_rootfs.sh
# (no dependency on phone-side Wi-Fi).
SETUP_SRC="$ROOT/scripts/setup_kenzo.sh"
if [[ -f "$SETUP_SRC" ]]; then
  install -m755 "$SETUP_SRC" "$R/home/$KENZO_USER/setup_kenzo.sh"
  chroot "$R" chown "$KENZO_USER:$KENZO_USER" "/home/$KENZO_USER/setup_kenzo.sh"
  install -m755 "$SETUP_SRC" "$R/usr/local/sbin/setup_kenzo.sh"
fi
# Copy .env configuration to /etc/kenzo.env
if [[ -f "$ROOT/.env" ]]; then
  install -m600 "$ROOT/.env" "$R/etc/kenzo.env"
fi
# ---- BUILD-TIME userland: packages + dotfiles + tooling (inside the chroot) ----
# The build HOST has internet, so install eza/fastfetch/delta/node/oh-my-zsh/... now.
# setup_rootfs.sh is idempotent-ish (skips if things already exist on rebuilds).
if [[ -f "$ROOT/scripts/setup_rootfs.sh" ]]; then
  echo "==> running setup_rootfs.sh (chroot) to pre-install userland packages & config..."
  install -m755 "$ROOT/scripts/setup_rootfs.sh" "$R/setup_rootfs.sh"
  if ! chroot "$R" env SKIP_DOCKER="${SKIP_DOCKER:-false}" /setup_rootfs.sh "$KENZO_USER"; then
    echo "WARNING: setup_rootfs.sh had non-zero exit (see above). Continuing anyway." >&2
  fi
  rm -f "$R/setup_rootfs.sh"
  echo "==> setup_rootfs.sh completed"
fi
for f in ".zshrc" ".oh-my-zsh/oh-my-zsh.sh"; do
  [[ -s "$R/home/$KENZO_USER/$f" ]] || echo "WARNING: $R/home/$KENZO_USER/$f is missing: setup_rootfs.sh stopped early (look for 'setup_rootfs.sh FAILED at line' above)" >&2
done
HOST_NAME="${KENZO_HOSTNAME:-kenzo}"
echo "$HOST_NAME" > "$R/etc/hostname"; printf "127.0.0.1 localhost %s\n" "$HOST_NAME" > "$R/etc/hosts"

# Apply battery charging thresholds from .env to kenzo-battery.conf
if [[ -f "$R/etc/kenzo-battery.conf" ]]; then
  sed -i "s/^STOP_THRESHOLD=.*/STOP_THRESHOLD=${BATTERY_STOP_THRESHOLD:-60}/" "$R/etc/kenzo-battery.conf"
  sed -i "s/^START_THRESHOLD=.*/START_THRESHOLD=${BATTERY_START_THRESHOLD:-58}/" "$R/etc/kenzo-battery.conf"
  sed -i "s/^CHECK_INTERVAL_SEC=.*/CHECK_INTERVAL_SEC=${BATTERY_CHECK_INTERVAL_SEC:-30}/" "$R/etc/kenzo-battery.conf"
fi
# no UART assumed: getty on tty1 (fbcon) is on by default; enable services
chroot "$R" systemctl enable getty@tty1.service kenzo-powerkey.service usb-gadget-rndis.service ssh.service NetworkManager.service systemd-modules-load.service kenzo-screen-banner.service kenzo-zram.service kenzo-wifi-regdom.service kenzo-wifi-band.timer kenzo-batteryd.service avahi-daemon.service systemd-timesyncd.service || true

if [[ "${SKIP_BLUETOOTH:-false}" == "true" ]]; then
  echo "==> Masking bluetooth.service (SKIP_BLUETOOTH=true; saves ~10MB RAM)..."
  chroot "$R" systemctl mask bluetooth.service 2>/dev/null || true
  chroot "$R" systemctl disable bluetooth.service 2>/dev/null || true
else
  chroot "$R" systemctl enable bluetooth.service 2>/dev/null || true
fi

# kernel modules (built by build-kernel.sh into out/modroot) -> /lib/modules  (REQUIRED for Wi-Fi/BT/Docker/TUN)
MODSRC="$ROOT/out/modroot/lib/modules"
if [[ -d "$MODSRC" ]]; then
  KVER="$(ls "$MODSRC" | head -1)"
  echo "==> installing kernel modules ($KVER) into rootfs"
  cp -a "$MODSRC" "$R/lib/"
  if [[ "${SKIP_VENUS:-${SKIP_BROKEN:-true}}" == "true" ]]; then
    echo "==> Excluding Venus video codec modules (SKIP_VENUS=true)..."
    find "$R/lib/modules" -iname "*venus*" -delete 2>/dev/null || true
    rm -rf "$R/usr/lib/firmware/qcom/venus"* "$R/usr/lib/firmware/qcom/vpu"* 2>/dev/null || true
  fi
  if [[ -n "$KVER" ]]; then
    chroot "$R" depmod -a "$KVER" || { echo "depmod $KVER FAILED" >&2; exit 1; }
    # sanity: the modules we need for Wi-Fi/BT must exist after depmod
    for need_mod in wcn36xx wcnss_ctrl qcom_wcnss_pil btqcomsmd bluetooth rfkill cfg80211 mac80211; do
      if ! chroot "$R" modprobe -S "$KVER" -n "$need_mod" >/dev/null 2>&1 && ! grep -q "$need_mod" "$R/lib/modules/$KVER/modules.builtin" 2>/dev/null; then
        echo "  WARNING: module $need_mod not resolvable in $KVER (check out/modroot)" >&2
      fi
    done
    echo "  modules installed OK"
  fi
else
  cat >&2 << 'E'
ERROR: out/modroot/lib/modules is missing. Run ./scripts/build-kernel.sh FIRST (it produces
       out/modroot via modules_install). Wi-Fi, Bluetooth, Docker/TUN and any driver built as
       =m WILL NOT WORK because /lib/modules will be empty. Rebuilding without modules...
E
  exit 1
fi
if [[ "${SKIP_DOCKER:-false}" != "true" && "${SKIP_DOCKER:-false}" != "1" ]]; then
  # Docker: Ubuntu's docker.io; networking forwarding persisted
  install -d "$R/etc/sysctl.d"
  printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\nnet.ipv6.conf.default.forwarding = 1\n' > "$R/etc/sysctl.d/99-docker.conf"
  chroot "$R" update-alternatives --set iptables /usr/sbin/iptables-nft 2>/dev/null || true
  chroot "$R" systemctl enable docker.service containerd.service || true
else
  echo "==> Skipping Docker service configuration (SKIP_DOCKER=true)..."
  chroot "$R" systemctl disable docker.service containerd.service 2>/dev/null || true
  rm -f "$R/etc/sysctl.d/99-docker.conf"
fi
# image
MB=$(( $(du -sm "$R" | cut -f1) + 768 )); IMG="$ROOT/out/rootfs.ext4"
rm -f "$IMG"; truncate -s ${MB}M "$IMG"; mkfs.ext4 -F -L userdata "$IMG" >/dev/null
M=$(mktemp -d); mount -o loop "$IMG" "$M"; cp -a "$R"/. "$M"/; umount "$M"; rmdir "$M"
img2simg "$IMG" "$ROOT/out/rootfs.sparse.img" 2>/dev/null || true
ls -lh "$ROOT/out"/rootfs*.img "$IMG" 2>/dev/null
