#!/bin/sh
# Ask, in the session that just took over, whether to log out the other one.
#   ask-close-other.sh remote   -> asked on the desk:   "Remote session still running"
#   ask-close-other.sh desk     -> asked in the remote: "Desk session still logged in"
# Called (in the background) by rdp-gate.py on desk takeover and by on-connect.sh on RDP login.
#   ask-close-other.sh desk|remote --now   log it out without asking (the plugin's buttons)

HERE=$(cd "$(dirname "$0")" && pwd)

remote_hypr_pid() {
    CG=$(systemctl --user show -p ControlGroup --value hyprland-remote.service)
    [ -n "$CG" ] || return
    for p in $(cat "/sys/fs/cgroup$CG/cgroup.procs" 2>/dev/null); do
        [ "$(cat /proc/$p/comm 2>/dev/null)" = Hyprland ] && { echo "$p"; return; }
    done
}
desk_session() {
    loginctl list-sessions --no-legend | awk -v u="$(id -un)" '$3==u && $4=="seat0" {print $1; exit}'
}

case "$1" in
remote)
    systemctl --user is-active -q hyprland-remote.service || exit 0
    TITLE="RDP session is still logged in"
    SHOW_IN=desk
    WHERE_SHORT="in the RDP session instead of here"
    ;;
desk)
    S=$(desk_session); [ -n "$S" ] || exit 0
    P=$(remote_hypr_pid); [ -n "$P" ] || exit 1
    TITLE="Console session is still logged in"
    SHOW_IN=remote
    WHERE_SHORT="on the console instead of here"
    ;;
*) echo "usage: $0 remote|desk" >&2; exit 2 ;;
esac
if [ "${2:-}" = --now ]; then
    CHOICE=logout
else
# Asked by the Omarchy RDP plugin, in its bar panel in the session that took over: the
# question with Log it out / Keep it / Why? (Why? shows the explanation). Closing the panel
# keeps the other session.
W=$("$HERE/hypr-session.sh" "$SHOW_IN" | awk '{print $2}')
[ -n "$W" ] || exit 1
export WAYLAND_DISPLAY="$W" OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"

# A freshly started session (the gate starts the remote one on the RDP login that asks
# this) takes a few seconds to bring up its shell and the plugin: wait for it.
for i in $(seq 60); do
    [ "$(omarchy-shell omarchy-rdp refresh 2>/dev/null)" = ok ] && break
    sleep 1
done

WHY="Both sessions are you, the same user, and some apps only allow one copy per user, like browsers on the same profile, chat and music apps and password managers. Any still open there would open their windows $WHERE_SHORT, or say they're already running. Logging it out closes them, so they open where you are."
ANS="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rdp-sessions/answer-$$"
mkdir -p "$(dirname "$ANS")"; rm -f "$ANS"
omarchy-shell omarchy-rdp ask "$TITLE" "$WHY" "$ANS" >/dev/null 2>&1 || exit 1
i=0
while [ ! -e "$ANS" ]; do
    sleep 0.5
    i=$((i + 1))
    # Every few seconds: still asking? (A shell restart in that session loses the question.)
    if [ $((i % 10)) = 0 ] && [ "$(omarchy-shell omarchy-rdp pending 2>/dev/null)" != "$ANS" ]; then
        [ -e "$ANS" ] || exit 0
    fi
done
CHOICE=$(cat "$ANS"); rm -f "$ANS"
fi


if [ "$CHOICE" = logout ]; then
    case "$1" in
    remote) systemctl --user stop hyprland-remote.service ;;   # next RDP login starts a fresh one
    desk)   # console returns to SDDM's login screen
        # The way Omarchy's own Log Out does it (`uwsm stop`), on the desk's session bus
        # (the remote session has its own). Killing the session with loginctl instead
        # takes SDDM's helper with it: SDDM treats that as a crash, starts no greeter,
        # and the console is left with no display.
        S=$(desk_session)
        DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus" /usr/bin/uwsm stop \
            || loginctl terminate-session "$S"
        ;;
    esac
fi
