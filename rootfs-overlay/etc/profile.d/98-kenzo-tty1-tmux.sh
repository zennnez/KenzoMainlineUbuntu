#!/usr/bin/env sh
# The phone's own screen (tty1) keeps its shell inside the tmux session "kenzo", so that `kenzo-cmd`
# can run things on the display. Opt out with:  touch ~/.kenzo-no-tmux
# If tmux fails the plain shell stays; when the session ends normally the login ends (getty restarts it).
if [ -z "${TMUX:-}" ] && [ -z "${SSH_CONNECTION:-}" ] && [ ! -e "$HOME/.kenzo-no-tmux" ] \
   && [ "$(tty 2>/dev/null)" = /dev/tty1 ] && command -v tmux >/dev/null 2>&1; then
    if tmux new-session -A -s kenzo; then exit; fi
fi
