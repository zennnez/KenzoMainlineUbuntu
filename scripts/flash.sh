#!/usr/bin/env bash
# usage: flash.sh test | boot | lk2nd | rootfs      (device in lk2nd fastboot)
#   test   -> fastboot boot out/boot.img   (RAM only, nothing written)  <- do this first
#   boot   -> fastboot flash boot out/boot.img   (lk2nd flashes this at +512 KiB of the boot partition; lk2nd itself stays)
#   lk2nd  -> fastboot flash lk2nd $LK2ND  (only if you really want to replace lk2nd; default: assets/lk2nd-from-lineage-boot.img)
#   rootfs -> flash 'userdata' (WIPES Android data)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/scripts/env.sh" ]] && source "$ROOT/scripts/env.sh"
IMG="${BOOTIMG:-$ROOT/out/boot.img}"

# Auto-detect fastboot: on WSL, USB devices are connected to Windows unless usbipd is used.
# If Linux fastboot sees no devices but fastboot.exe does, use fastboot.exe with Windows paths.
FASTBOOT="fastboot"
fb_path() { echo "$1"; }

if command -v fastboot.exe >/dev/null 2>&1; then
  if [[ -z "$(fastboot devices 2>/dev/null || true)" ]] && [[ -n "$(fastboot.exe devices 2>/dev/null || true)" ]]; then
    FASTBOOT="fastboot.exe"
    fb_path() { wslpath -m "$1"; }
  fi
fi

# Refuse hybrid images: under lk2nd they end up as "a second lk2nd where Linux should be" -> lk2nd falls back to fastboot.
check_img() { python3 "$ROOT/tools/bootimg.py" verify "$IMG" >/dev/null || { python3 "$ROOT/tools/bootimg.py" verify "$IMG" || true; exit 1; }; }
case "${1:-}" in
  test)   check_img; "$FASTBOOT" boot "$(fb_path "$IMG")" ;;
  boot)   check_img; "$FASTBOOT" flash boot "$(fb_path "$IMG")" ;;
  lk2nd)  "$FASTBOOT" flash lk2nd "$(fb_path "${LK2ND:-$ROOT/assets/lk2nd-from-lineage-boot.img}")" ;;
  rootfs) read -rp "This ERASES userdata. Type yes: " a; [[ $a == yes ]]
          "$FASTBOOT" flash userdata "$(fb_path "$ROOT/out/rootfs.sparse.img")" ;;
  *) sed -n 2,7p "$0"; exit 1 ;;
esac
