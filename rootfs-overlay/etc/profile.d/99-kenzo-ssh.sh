#!/usr/bin/env sh
# The connection details (Wi-Fi band, SSH commands for Wi-Fi/USB/name/Tailscale, Bluetooth) are now part
# of fastfetch (/etc/fastfetch/config.jsonc), so there is no separate banner any more.
# zsh runs fastfetch from ~/.zshrc; plain bash login shells over SSH get it here.
if [ -n "${BASH_VERSION:-}" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -t 1 ] && command -v fastfetch >/dev/null 2>&1; then
    case $- in *i*) fastfetch ;; esac
fi
