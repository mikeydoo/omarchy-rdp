#!/bin/sh
# ExecStop of hyprland-remote.service: end the remote session the way a logout does.
# systemd's default stop sends SIGTERM to everything at once, and start-hyprland
# (Hyprland's launcher) aborts on SIGTERM, leaving a core dump and a crash notification.
# So: stop the session's portals first (as uwsm does on the desk; they crash when their
# compositor disappears under them), then ask Hyprland to exit, which start-hyprland sees
# as a clean exit. Whatever is left gets systemd's normal stop afterwards.
CG=$(systemctl --user show -p ControlGroup --value hyprland-remote.service)
procs() { cat "/sys/fs/cgroup$CG/cgroup.procs" 2>/dev/null; }
[ -n "$CG" ] || exit 0

portals=""
for p in $(procs); do
    case "$(cat /proc/$p/comm 2>/dev/null)" in xdg-desktop-por*) portals="$portals $p" ;; esac
done
if [ -n "$portals" ]; then
    kill -TERM $portals 2>/dev/null
    for i in $(seq 20); do
        alive=""; for p in $portals; do [ -d /proc/$p ] && alive=1; done
        [ -n "$alive" ] || break
        sleep 0.1
    done
fi

session=$("$HOME/.config/hypr-rdp/hypr-session.sh" remote) || exit 0
set -- $session   # signature, wayland socket, pid
HYPRLAND_INSTANCE_SIGNATURE=$1 hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || exit 0
for i in $(seq 100); do        # up to 10 s
    [ -d "/proc/$3" ] || exit 0
    sleep 0.1
done
