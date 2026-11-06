#!/usr/bin/env bash
# Builds TWO images (same kernel/initramfs/dtb/cmdline):
#
#   out/boot.img         PLAIN Android boot image (v2).  <-- use this for `fastboot boot` and `fastboot flash boot`
#   out/boot-hybrid.img  lk2nd (512 KiB) + the plain image @512 KiB, like your Lineage boot.img.
#                        Only for raw whole-partition writes (dd / recovery zip). NEVER `fastboot flash boot` it.
#
# Why two: under lk2nd's fastboot the "boot" partition is the real boot partition minus its first 512 KiB
# (virtual "lk2nd" partition).  `fastboot flash boot hybrid.img` therefore writes a 2nd lk2nd image where lk2nd
# looks for Linux, and lk2nd falls back to fastboot ("Could not do normal boot. Reverting to fastboot mode").
#
# Overrides:  KERNEL=path/to/Image.gz (e.g. one from extract-from-bootimg.sh)   DTB=path/to/file.dtb
#             LK2ND=path/to/lk2nd.img   CMDLINE="..."   RAMDISK=path/to/initramfs.cpio.gz
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env.sh"
OUT="$ROOT/out"; mkdir -p "$OUT"
# Default: the lk2nd that was inside your working Lineage boot.img (the other asset is the older pmOS 23.1 build)
LK2ND="${LK2ND:-$ROOT/assets/lk2nd-from-lineage-boot.img}"
KERNEL="${KERNEL:-$OUT/Image.gz}"
DTB="${DTB:-$OUT/$DTB_NAME}"
if [[ -z "${RAMDISK:-}" ]]; then
  [[ -s "$OUT/initramfs.cpio.gz" ]] || "$ROOT/scripts/build-initramfs.sh"
  RAMDISK="$OUT/initramfs.cpio.gz"
fi
for f in "$KERNEL" "$DTB" "$RAMDISK"; do [[ -s "$f" ]] || { echo "missing $f (run build-kernel.sh, or set KERNEL=/DTB=)" >&2; exit 1; }; done
# Lineage cmdline minus Android bits. No maxcpus: MSM8956 = 4x A53 + 2x A72 (6 CPUs); patches/kernel/0002 stops the DTS from
# describing the two A72 cores that do not exist. Keep lk2nd.pass-ramoops=zap.
# Default is quiet (loglevel=3: only crit+ on the console; everything is still in dmesg/pstore). SSH over RNDIS works, and
# ignore_loglevel+loglevel=8 made USB/RNDIS gadget errors spam fbcon. Early bring-up/debug: KENZO_VERBOSE=1 ./scripts/build-bootimg.sh
if [[ "${KENZO_VERBOSE:-0}" == 1 ]]; then LOGARGS="ignore_loglevel loglevel=8"; else LOGARGS="loglevel=3"; fi
CMDLINE="${CMDLINE:-console=tty0 console=ttyMSM0,115200n8 $LOGARGS log_buf_len=4M printk.devkmsg=on nospectre_v2 lk2nd.pass-ramoops=zap rw rootwait}"

# Fix known DTS problems in the compiled DTB itself (ADSP wdog IRQ crash loop, the two A72 cores MSM8956 does not have).
# Works on whatever kernel tree you built; idempotent. Skip with KENZO_NO_DTB_FIX=1. Tune CPUs with KENZO_DISABLE_CPUS.
if [[ "${KENZO_NO_DTB_FIX:-0}" != 1 ]]; then
  echo "==> fixing known DTS problems in the DTB (scripts/fix-dtb.sh)"
  "$ROOT/scripts/fix-dtb.sh" "$DTB" "$OUT/fixed.dtb"; DTB="$OUT/fixed.dtb"
fi

python3 "$ROOT/tools/bootimg.py" pack -o "$OUT/boot.img" \
  --kernel "$KERNEL" --ramdisk "$RAMDISK" --dtb "$DTB" --cmdline "$CMDLINE"
python3 "$ROOT/tools/bootimg.py" pack -o "$OUT/boot-hybrid.img" \
  --kernel "$KERNEL" --ramdisk "$RAMDISK" --dtb "$DTB" --cmdline "$CMDLINE" --hybrid "$LK2ND"

echo "==> verifying out/boot.img"
python3 "$ROOT/tools/bootimg.py" verify "$OUT/boot.img"
ls -lh "$OUT/boot.img" "$OUT/boot-hybrid.img"
echo "Test (RAM only):  ./scripts/flash.sh test"
echo "Install:          ./scripts/flash.sh boot      (flashes out/boot.img; lk2nd in the first 512 KiB stays untouched)"
