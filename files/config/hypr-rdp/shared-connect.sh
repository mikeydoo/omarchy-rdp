#!/bin/sh
# Shared mode: successful RDP login (hypr-rdp's on_session_start, after authentication).
# The desk session is shown as it is: if it's locked, unlock it over RDP.
M="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rdp-sessions"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-rdp/logins.tsv"
mkdir -p "$(dirname "$LOG")"
printf '%s\trdp\t%s\n' "$(date +%s)" "$(cat "$M/client" 2>/dev/null)" >> "$LOG"
tail -n 50 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
mkdir -p "$M" && : > "$M/shared-connected"   # shared-disconnect.sh locks only after this
exit 0
