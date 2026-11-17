#!/bin/sh
# Shared mode: the RDP client disconnected (hypr-rdp's on_session_end). Lock the desk
# session, so the console isn't left open; the next RDP login shows the lock screen.
# hypr-rdp runs in the desk session, so its Hyprland and display are in the environment.
# hypr-rdp also runs this when its service stops (switching mode, updates): lock only if a
# client had logged in.
M="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rdp-sessions"
[ -e "$M/shared-connected" ] || exit 0
rm -f "$M/shared-connected"
OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy} omarchy-system-lock >/dev/null 2>&1
exit 0
