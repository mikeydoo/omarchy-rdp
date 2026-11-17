#!/bin/sh
# Ask, in the session that just took over, whether to log out the other one.
#   ask-close-other.sh remote   -> asked on the desk:   "Remote session still running"
#   ask-close-other.sh desk     -> asked in the remote: "Desk session still logged in"
# Called (in the background) by rdp-gate.py on desk takeover and by on-connect.sh on RDP login.
#   ask-close-other.sh desk|remote --now   log it out without asking (the plugin's buttons)

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
    BUS="unix:path=$XDG_RUNTIME_DIR/bus"   # the desk's session bus
    TITLE="Remote session is still running"
    BODY="Your RDP session is still logged in with its windows open. Log it out?"
    ;;
desk)
    S=$(desk_session); [ -n "$S" ] || exit 0
    P=$(remote_hypr_pid); [ -n "$P" ] || exit 1
    BUS=$(tr '\0' '\n' < /proc/$P/environ | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
    TITLE="Desk session is still logged in"
    BODY="Your console session is still logged in with its windows open. Log it out?"
    ;;
*) echo "usage: $0 remote|desk" >&2; exit 2 ;;
esac
if [ "${2:-}" = --now ]; then
    CHOICE=logout
else
[ -n "$BUS" ] || exit 1

CHOICE=$(DBUS_SESSION_BUS_ADDRESS=$BUS notify-send -a "Sessions" -u critical -t 0 \
    -A logout="Log it out" -A keep="Keep it" "$TITLE" "$BODY")
fi

if [ "$CHOICE" = logout ]; then
    case "$1" in
    remote) systemctl --user stop hyprland-remote.service ;;   # next RDP login starts a fresh one
    desk)   # console returns to the greeter
        S=$(desk_session)
        loginctl terminate-session "$S"
        # Killed this way, the desk Hyprland skips its exit cleanup and leaves
        # graphical-session.target active; uwsm then refuses the next desk login
        # ("A compositor or graphical-session* target is already active!").
        for i in $(seq 20); do loginctl show-session "$S" >/dev/null 2>&1 || break; sleep 0.5; done
        systemctl --user stop graphical-session.target
        ;;
    esac
fi
