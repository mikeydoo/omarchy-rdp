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
# Asked with Omarchy's own menu (omarchy-menu-select) in the session that took over: a
# fixed box in the middle of the screen, unlike a notification. Dismissing it (Escape,
# clicking outside) keeps the other session.
W=$("$HERE/hypr-session.sh" "$SHOW_IN" | awk '{print $2}')
[ -n "$W" ] || exit 1
export WAYLAND_DISPLAY="$W" OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"

# A freshly started session (the gate starts the remote one on the RDP login that asks
# this) takes a few seconds to bring up its shell, which shows the menu: wait for it.
for i in $(seq 60); do
    [ "$(omarchy-shell notifications ping 2>/dev/null)" = ok ] && break
    sleep 1
done
sleep 1

TAB=$(printf '\t')
row() { printf '%s\t%s\t%s' "$1" "$2" "$3"; }   # glyph, label, caption
LOGOUT=$(row "$(printf '\uf08b')" "Log it out" "Closes its windows, so apps open here")
KEEP=$(row "$(printf '\uf00c')" "Keep it" "Leaves its windows open")
WHYROW=$(row "$(printf '\uf059')" "Why?" "Some apps only allow one copy per user")
ask() { omarchy-menu-select "$@" -- --width 560 2>/dev/null | cut -d"$TAB" -f1; }

CHOICE=$(ask "$TITLE" "$LOGOUT" "$KEEP" "$WHYROW")
# Why?: the explanation, then the same choice again (picking an explanation row shows it
# again; dismissing the menu keeps the other session).
while [ -n "$CHOICE" ] && [ "$CHOICE" != "Log it out" ] && [ "$CHOICE" != "Keep it" ]; do
    CHOICE=$(ask "Why log it out?" \
        "$(row "$(printf '\uf007')" "Both sessions are you, the same user" "Some apps only allow one copy per user")" \
        "$(row "$(printf '\uf2d2')" "Like browsers, chat and music apps" "and password managers: one session at a time")" \
        "$(row "$(printf '\uf2d0')" "Any still open there open their windows there" "$WHERE_SHORT, or say they're already running")" \
        "$(row "$(printf '\uf0e2')" "Logging it out closes its apps" "so they open where you are")" \
        "$LOGOUT" "$KEEP")
done
case "$CHOICE" in
    "Log it out") CHOICE=logout ;;
    *) CHOICE=keep ;;
esac
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
