#!/bin/sh
# Find this user's two Hyprland instances.
#   hypr-session.sh remote   the headless remote session (hyprland-remote.service)
#   hypr-session.sh desk     the desk session (any other running instance)
# Prints "<instance signature> <wayland socket> <pid>", or exits 1 when there is none.
remote_pid() {
    cg=$(systemctl --user show -p ControlGroup --value hyprland-remote.service 2>/dev/null)
    [ -n "$cg" ] || return 0
    for p in $(cat "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null); do
        [ "$(cat "/proc/$p/comm" 2>/dev/null)" = Hyprland ] && { echo "$p"; return 0; }
    done
}

case ${1:-} in
remote | desk) ;;
*) echo "usage: $0 remote|desk" >&2; exit 2 ;;
esac

rp=$(remote_pid)
hyprctl instances -j 2>/dev/null | jq -r --arg want "$1" --arg rp "${rp:-0}" '
    map(select(if $want == "remote" then (.pid | tostring) == $rp
               else (.pid | tostring) != $rp end))
    | first // empty | "\(.instance) \(.wl_socket) \(.pid)"' | grep . || exit 1
