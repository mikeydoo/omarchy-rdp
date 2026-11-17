#!/bin/sh
# Run hypr-rdp against the headless remote session (hyprland-remote.service).
# The service's main process is dbus-run-session; find the Hyprland process in its cgroup.
hypr_pid() {
    CG=$(systemctl --user show -p ControlGroup --value hyprland-remote.service)
    [ -n "$CG" ] || return
    for p in $(cat "/sys/fs/cgroup$CG/cgroup.procs" 2>/dev/null); do
        [ "$(cat /proc/$p/comm 2>/dev/null)" = Hyprland ] && { echo "$p"; return; }
    done
}
for i in $(seq 30); do
    PID=$(hypr_pid)
    [ -n "$PID" ] || { sleep 1; continue; }
    SIG=$(hyprctl instances -j 2>/dev/null |
          python3 -I -c 'import sys,json; p=int(sys.argv[1]); [print(i["instance"], i["wl_socket"]) for i in json.load(sys.stdin) if i["pid"]==p]' "$PID")
    [ -n "$SIG" ] && break; sleep 1
done
[ -n "$SIG" ] || { echo "no Hyprland instance found in hyprland-remote.service" >&2; exit 1; }
set -- $SIG
export HYPRLAND_INSTANCE_SIGNATURE=$1 WAYLAND_DISPLAY=$2
exec hypr-rdp
