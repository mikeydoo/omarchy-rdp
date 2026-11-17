#!/bin/sh
# Start a headless-only Hyprland (no seat, no screens) for the RDP remote session.
# Run by hyprland-remote.service. Uses the patched libaquamarine in ./lib and the remote
# session's own Hyprland config, ~/.config/hypr-rdp/hyprland-remote.lua (or the config
# given as $1), which loads Omarchy's defaults and your ~/.config/hypr files without
# Omarchy's desk autostart.
HERE=$(cd "$(dirname "$0")" && pwd)
CONFIG=${1:-$HOME/.config/hypr-rdp/hyprland-remote.lua}

# The patched lib must match the system aquamarine (rebuild-if-stale.sh, run as the
# service's ExecStartPre, sees to that; this is the safety net).
WANT=$(pacman -Q aquamarine 2>/dev/null | awk '{print $2}' | sed 's/-.*//')
HAVE=$(cat "$HERE/lib/AQUAMARINE_VERSION" 2>/dev/null)
if [ "$WANT" != "$HAVE" ]; then
    echo "patched libaquamarine is for '$HAVE' but the system has '$WANT':" \
         "run $HERE/rebuild-if-stale.sh" >&2
    exit 1
fi
[ -f "$CONFIG" ] || { echo "remote session config not found: $CONFIG" >&2; exit 1; }

RENDER_NODE=${AQ_HEADLESS_RENDER_NODE:-$(ls /dev/dri/renderD* 2>/dev/null | head -1)}
[ -n "$RENDER_NODE" ] || { echo "no /dev/dri/renderD* render node found" >&2; exit 1; }

# - WAYLAND_DISPLAY/HYPRLAND_INSTANCE_SIGNATURE/DISPLAY: don't attach to the desk session.
# - XDG_SESSION_ID/SEAT/VTNR come from the desk session via the systemd user env; without
#   unsetting them the remote session would report to (and Log Out would act on) the desk.
# - PATH: ./bin first. Its uwsm-app runs apps directly: Omarchy launches apps through
#   uwsm-app, which would start them with the desk's environment, on the desk.
# - OMARCHY_PATH and the XDG_* session vars: at boot the remote session starts before the
#   desk has imported them into the systemd user env.
# - LIBSEAT_BACKEND=none (no such backend): libseat fails, so aquamarine never opens a
#   seat or the GPU's display (card) device and runs headless only. Otherwise, at boot,
#   the remote session can start before the desk and take seat0 through logind; the desk's
#   Hyprland then crashes (CBackend::create() failed) and SDDM falls back to its greeter.
# - AQ_HEADLESS_RENDER_NODE: enables the patch; hyprland-remote.lua also uses it to
#   recognise the remote session.
# - start-hyprland: Hyprland's own launcher (a watchdog); started directly, Hyprland shows
#   "Hyprland was started without start-hyprland".
# - dbus-run-session: the remote session gets its own session bus, so single-instance apps
#   (GNOME apps, browsers, ...) and notifications/MPRIS are per session.
exec env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY \
         -u XDG_SESSION_ID -u XDG_SEAT -u XDG_VTNR \
    PATH="$HERE/bin:$PATH" \
    OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}" \
    XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-Hyprland}" \
    XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-Hyprland}" \
    XDG_SESSION_TYPE=wayland LIBSEAT_BACKEND=none \
    AQ_HEADLESS_RENDER_NODE="$RENDER_NODE" LD_LIBRARY_PATH="$HERE/lib" \
    dbus-run-session -- start-hyprland -- --config "$CONFIG"
