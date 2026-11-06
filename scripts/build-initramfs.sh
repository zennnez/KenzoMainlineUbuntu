#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/scripts/env.sh" ]] && source "$ROOT/scripts/env.sh"
OUT="$ROOT/out"; ST="$OUT/initramfs-staging"; mkdir -p "$OUT"
[[ -f /usr/aarch64-linux-gnu/include/bits/wordsize.h ]] || { echo "missing arm64 libc headers: sudo apt install libc6-dev-arm64-cross" >&2; exit 1; }
aarch64-linux-gnu-gcc -static -Os -Wall -o "$OUT/initramfs-init" "$ROOT/initramfs/init.c"
rm -rf "$ST"; mkdir -p "$ST/sbin"
install -m755 "$OUT/initramfs-init" "$ST/init"; ln -sf ../init "$ST/sbin/init"
if [[ -d "$ROOT/firmware" ]]; then
  mkdir -p "$ST/lib/firmware"
  for f in "$ROOT/firmware/"*; do
    [[ -e "$f" ]] || continue
    bn="$(basename "$f")"
    if [[ "${DISABLE_ADSP:-${SKIP_BROKEN:-true}}" == "true" ]] && [[ "$bn" == adsp.* ]]; then
      continue
    fi
    cp -a "$f" "$ST/lib/firmware/" 2>/dev/null || true
  done
fi
( cd "$ST" && find . -print0 | cpio --null -o --format=newc ) | gzip -9 > "$OUT/initramfs.cpio.gz"
ls -lh "$OUT/initramfs.cpio.gz"
