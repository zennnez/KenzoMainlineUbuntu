#!/usr/bin/env bash
# Apply patches/kernel/*.patch to $KERNEL_SRC (your clone of msm8956-mainline-linux). Safe to run repeatedly:
#   not applied yet      -> applied
#   already applied      -> skipped
#   neither (tree moved) -> warning only: scripts/fix-dtb.sh applies the same fixes to the compiled DTB anyway
#                           (KENZO_STRICT_PATCHES=1 turns the warning into an error)
# The patches change the working tree only (no commits), so `git checkout -- arch/` or `git stash` undoes them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env.sh"
[[ "${KENZO_SKIP_PATCHES:-0}" == 1 ]] && { echo "==> KENZO_SKIP_PATCHES=1: not applying kernel patches"; exit 0; }
[[ -d "$KERNEL_SRC" ]] || { echo "kernel tree $KERNEL_SRC not found" >&2; exit 1; }
cd "$KERNEL_SRC"
shopt -s nullglob
for p in "$ROOT"/patches/kernel/*.patch; do
  n="$(basename "$p")"
  if git apply --check "$p" 2>/dev/null; then
    if git apply "$p" 2>/dev/null; then
      echo "  applied        $n"
    else
      echo "  failed to apply $n (skipping)"
    fi
  elif git apply --check --reverse "$p" 2>/dev/null; then
    echo "  already in tree $n"
  else
    echo "  skipping $n (does not apply or already modified)"
  fi
done
exit 0
