#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$ROOT/out/rootfs"
IMG="$ROOT/out/rootfs.ext4"
SPARSE="$ROOT/out/rootfs.sparse.img"

# Ensure ufw is disabled by default to prevent SSH lockout
sed -i 's/^ENABLED=yes/ENABLED=no/' "$R/etc/ufw/ufw.conf" 2>/dev/null || true

echo "==> Packing rootfs into ext4 and sparse image..."
MB=$(( $(du -sm "$R" | cut -f1) + 768 ))
rm -f "$IMG" "$SPARSE"
truncate -s ${MB}M "$IMG"
mkfs.ext4 -F -L userdata "$IMG" >/dev/null
M=$(mktemp -d)
mount -o loop "$IMG" "$M"
cp -a "$R"/. "$M"/
umount "$M"
rmdir "$M"
img2simg "$IMG" "$SPARSE"
chown -R 1000:1000 "$IMG" "$SPARSE" 2>/dev/null || true
ls -lh "$IMG" "$SPARSE"
echo "==> Done."
