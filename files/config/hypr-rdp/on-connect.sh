#!/bin/sh
# Successful RDP login (hypr-rdp on_session_start: runs only after authentication).
# Newest login wins: lock the desk session with Omarchy's own lock (`omarchy system lock`),
# pointed at the desk's Hyprland. If the desk was used since the last RDP login, ask in
# the remote session whether to log it out.
HERE=$(cd "$(dirname "$0")" && pwd)
M="$XDG_RUNTIME_DIR/rdp-sessions"; mkdir -p "$M"
touch "$M/remote-used"              # rdp-gate.py asks on the desk next time it's unlocked

# Login history for the plugin (last 50 kept). The gate wrote the client's address.
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-rdp/logins.tsv"
mkdir -p "$(dirname "$LOG")"
printf '%s\trdp\t%s\n' "$(date +%s)" "$(cat "$M/client" 2>/dev/null)" >> "$LOG"
tail -n 50 "$LOG" > "$LOG.$$.tmp" && mv "$LOG.$$.tmp" "$LOG"

if desk=$("$HERE/hypr-session.sh" desk); then
    set -- $desk
    HYPRLAND_INSTANCE_SIGNATURE=$1 WAYLAND_DISPLAY=$2 \
        OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy} omarchy-system-lock
fi

if [ -e "$M/desk-used" ]; then          # set by rdp-gate.py when the desk gets unlocked
    rm -f "$M/desk-used"
    setsid -f "$HERE/ask-close-other.sh" desk >/dev/null 2>&1
fi
exit 0
