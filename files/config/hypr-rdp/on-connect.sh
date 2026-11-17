#!/bin/sh
# Successful RDP login (hypr-rdp on_session_start, runs only after authentication).
# Newest login wins: lock this user's desk (seat0) session.
# If the desk was used since the last RDP login, ask in the remote session whether to log it out.
M="$XDG_RUNTIME_DIR/rdp-sessions"; mkdir -p "$M"
touch "$M/remote-used"              # rdp-gate.py asks on the desk next time it's unlocked

S=$(loginctl list-sessions --no-legend | awk -v u="$(id -un)" '$3==u && $4=="seat0" {print $1; exit}')
[ -n "$S" ] && loginctl lock-session "$S"

if [ -e "$M/desk-used" ]; then          # set by rdp-gate.py when the desk gets unlocked
    rm -f "$M/desk-used"
    setsid -f $HOME/.config/hypr-rdp/ask-close-other.sh desk >/dev/null 2>&1
fi
exit 0
