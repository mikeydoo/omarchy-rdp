#!/bin/sh
# Shared mode (Omarchy RDP: "Share the desk session"): run hypr-rdp in the desk session,
# capturing the desk's monitor, so RDP shows and drives the same session as the console.
# Waits for a desk session; when the desk logs out hypr-rdp exits and the service starts
# this again (Restart=always), which waits for the next desk login.
HERE=$(cd "$(dirname "$0")" && pwd)
for i in $(seq 60); do
    desk=$("$HERE/hypr-session.sh" desk) && break
    sleep 2
done
[ -n "$desk" ] || { echo "no desk session to share" >&2; exit 1; }
set -- $desk   # signature, wayland socket, pid
export HYPRLAND_INSTANCE_SIGNATURE=$1 WAYLAND_DISPLAY=$2
OUTPUT=$(hyprctl monitors -j | jq -r 'first(.[] | select(.disabled | not) | .name) // empty')
[ -n "$OUTPUT" ] || { echo "the desk session has no monitor" >&2; exit 1; }
echo "sharing the desk session's $OUTPUT"
exec hypr-rdp --config "$HERE/config-shared.toml" --output "$OUTPUT"
