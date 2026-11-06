#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env.sh"
JOBS="${JOBS:-$(nproc)}"
OUT="$ROOT/out"; mkdir -p "$KBUILD_OUTPUT" "$OUT"
[[ -d "$KERNEL_SRC" ]] || { echo "clone the kernel to $KERNEL_SRC first" >&2; exit 1; }
cd "$KERNEL_SRC"

echo "==> Applying kernel patches (patches/kernel/)..."
"$ROOT/scripts/apply-kernel-patches.sh"

echo "==> Configuring kernel..."
make O="$KBUILD_OUTPUT" msm8956_defconfig
./scripts/kconfig/merge_config.sh -m -O "$KBUILD_OUTPUT" "$KBUILD_OUTPUT/.config" \
  "$ROOT/config/kenzo.fragment" \
  "$ROOT/config/kenzo-docker.fragment" \
  "$ROOT/config/kenzo-wireless.fragment"

# Apply granular SKIP_* kernel configuration
if [[ "${SKIP_TOUCH:-false}" == "true" || "${SKIP_TOUCH:-false}" == "1" ]]; then
  echo "==> Disabling touchscreen drivers (SKIP_TOUCH=true)..."
  ./scripts/config --file "$KBUILD_OUTPUT/.config" --disable CONFIG_TOUCHSCREEN_EDT_FT5X06
  ./scripts/config --file "$KBUILD_OUTPUT/.config" --disable CONFIG_TOUCHSCREEN_ATMEL_MXT
fi

if [[ "${SKIP_VENUS:-${SKIP_BROKEN:-true}}" == "true" || "${SKIP_VENUS:-${SKIP_BROKEN:-true}}" == "1" ]]; then
  echo "==> Disabling Venus hardware video codec (SKIP_VENUS=true)..."
  ./scripts/config --file "$KBUILD_OUTPUT/.config" --disable CONFIG_VIDEO_QCOM_VENUS
fi

make O="$KBUILD_OUTPUT" olddefconfig

echo "==> Building Image.gz, dtbs, modules with -j$JOBS..."
make O="$KBUILD_OUTPUT" -j"$JOBS" Image.gz dtbs modules

echo "==> Installing modules to $OUT/modroot..."
rm -rf "$OUT/modroot"
make O="$KBUILD_OUTPUT" INSTALL_MOD_PATH="$OUT/modroot" INSTALL_MOD_STRIP=1 modules_install >/dev/null

cp "$KBUILD_OUTPUT/arch/arm64/boot/Image.gz" "$OUT/Image.gz"
cp "$KBUILD_OUTPUT/arch/arm64/boot/dts/qcom/$DTB_NAME" "$OUT/$DTB_NAME"


echo "==> Kernel build completed successfully."
ls -lh "$OUT/Image.gz" "$OUT/$DTB_NAME"