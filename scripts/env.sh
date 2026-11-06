#!/usr/bin/env bash
# source scripts/env.sh
# Loads .env from repo root and exports build/runtime defaults.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env if present (respects pre-exported caller environment variables)
if [[ -f "$ROOT/.env" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    eval "$(python3 - << 'PYEOF' "$ROOT/.env"
import sys, re
try:
    with open(sys.argv[1], 'r', encoding='utf-8', errors='ignore') as f:
        text = f.read()
    pattern = re.compile(r"^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(?:'([^']*)'|\"([^\"]*)\"|([^\r\n#]*))", re.MULTILINE)
    for m in pattern.finditer(text):
        k = m.group(1)
        v = m.group(2) if m.group(2) is not None else (m.group(3) if m.group(3) is not None else m.group(4))
        v = v.strip()
        if v.startswith("~/"):
            import os
            v = os.path.expanduser(v)
        v_esc = v.replace("'", "'\\''")
        print(f"if [[ -z \"${{{k}+x}}\" ]]; then export {k}='{v_esc}'; fi")
except Exception:
    pass
PYEOF
)"
  else
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        var="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        val="${val/#\~/$HOME}"
        if [[ -z "${!var+x}" ]]; then export "$var=$val"; fi
      fi
    done < "$ROOT/.env"
  fi
fi

export ARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
KERNEL_SRC="${KERNEL_SRC:-$HOME/msm8956-mainline-linux}"
export KERNEL_SRC="${KERNEL_SRC/#\~/$HOME}"
export KBUILD_OUTPUT="${KBUILD_OUTPUT:-$ROOT/out/kernel}"
export DTB_NAME="${DTB_NAME:-msm8956-xiaomi-kenzo.dtb}"
export PATH="$HOME/.local/bin:$PATH"

# Build & System Defaults
export KENZO_USER="${KENZO_USER:-kenzo}"
export TIMEZONE="${TIMEZONE:-UTC}"
export SKIP_BROKEN="${SKIP_BROKEN:-true}"
export DISABLE_ADSP="${DISABLE_ADSP:-$SKIP_BROKEN}"
export SKIP_AUDIO="${SKIP_AUDIO:-$SKIP_BROKEN}"
export SKIP_CELLULAR="${SKIP_CELLULAR:-$SKIP_BROKEN}"
export SKIP_VENUS="${SKIP_VENUS:-$SKIP_BROKEN}"
export SKIP_TOUCH="${SKIP_TOUCH:-$SKIP_BROKEN}"
export SKIP_BLUETOOTH="${SKIP_BLUETOOTH:-false}"
export SKIP_DOCKER="${SKIP_DOCKER:-false}"
export KENZO_HOSTNAME="${KENZO_HOSTNAME:-kenzo}"
export KENZO_IP="${KENZO_IP:-192.168.7.2}"
export KENZO_HOST_IP="${KENZO_HOST_IP:-192.168.7.1}"
export BATTERY_STOP_THRESHOLD="${BATTERY_STOP_THRESHOLD:-60}"
export BATTERY_START_THRESHOLD="${BATTERY_START_THRESHOLD:-58}"
export BATTERY_CHECK_INTERVAL_SEC="${BATTERY_CHECK_INTERVAL_SEC:-30}"
export SUITE="${SUITE:-resolute}"
export MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
export THREADS="${THREADS:-$(nproc)}"
