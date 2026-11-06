#!/usr/bin/env bash
set -euo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo "$0" "$@"
apt-get update
apt-get install -y gcc-aarch64-linux-gnu libc6-dev-arm64-cross bc bison flex libssl-dev libncurses-dev libelf-dev \
  device-tree-compiler debootstrap qemu-user-static binfmt-support cpio gzip python3 zstd \
  abootimg mkbootimg android-sdk-libsparse-utils fastboot git
