#!/usr/bin/env bash
# usage: extract-from-bootimg.sh BOOT.IMG [OUTDIR]     (default OUTDIR=out/extracted)
# Pulls the parts out of a working boot.img (plain or lk2nd-hybrid; offset auto-detected):
#   Image.gz  Image  dtb  ramdisk  cmdline.txt  android-only.img  [lk2nd.img if hybrid]
# Use the Lineage kernel to rule the Ubuntu-built kernel in/out:
#   ./scripts/extract-from-bootimg.sh ~/boot.img
#   KERNEL=out/extracted/Image.gz DTB=out/extracted/dtb ./scripts/build-bootimg.sh && ./scripts/flash.sh test
# (Lineage's kernel has DRM/panels as modules and the Ubuntu rootfs has no matching /lib/modules, so expect a
#  working serial/USB-RNDIS + initramfs boot but possibly no display; that is enough to prove the boot chain.)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:?usage: $0 BOOT.IMG [OUTDIR]}"; OUTD="${2:-$ROOT/out/extracted}"
python3 "$ROOT/tools/bootimg.py" unpack "$IMG" -o "$OUTD"
ls -l "$OUTD"
