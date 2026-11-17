#!/bin/sh
# Make sure the patched libaquamarine in ./lib matches the system aquamarine, rebuilding it
# when it doesn't. Quick no-op when it already matches.
#
# Run by hyprland-remote.service (ExecStartPre) before every start of the remote session,
# and by the Omarchy post-update hook right after `omarchy update`.
#
# If the patch stops applying after an aquamarine update, the failed version is written to
# ./REBUILD_FAILED, the desk gets a notification, and later starts fail at once instead of
# rebuilding again. Port the patch, then re-run hypr-rdp/install.sh (which clears it).
# A failed download is not recorded: the next start simply tries again.
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=$HERE/lib
MARK=$HERE/REBUILD_FAILED

want=$(pacman -Q aquamarine 2>/dev/null | awk '{print $2}' | sed 's/-.*//')
[ -n "$want" ] || { echo "aquamarine is not installed" >&2; exit 1; }
current() { cat "$LIB/AQUAMARINE_VERSION" 2>/dev/null; }

[ "$(current)" = "$want" ] && exit 0

if [ "$(cat "$MARK" 2>/dev/null)" = "$want" ]; then
    echo "patched libaquamarine didn't build for aquamarine $want earlier:" \
         "port the patch, then re-run hypr-rdp/install.sh" >&2
    exit 1
fi

# One build at a time (the service and the post-update hook can overlap).
exec 9>"$HERE/.build.lock"
flock 9
[ "$(current)" = "$want" ] && exit 0

echo "patched libaquamarine is for '$(current)', the system has '$want': rebuilding"
"$HERE/build-aquamarine-headless.sh"
rc=$?
case $rc in
0)
    rm -f "$MARK"
    exit 0
    ;;
75)
    exit 1 # transient (download): try again on the next start
    ;;
*)
    echo "$want" > "$MARK"
    # The systemd user bus is the desk's (the remote session has its own, started later).
    notify-send -u critical "RDP remote session can't start" \
        "The patched libaquamarine didn't build for aquamarine $want (journalctl --user -u hyprland-remote). Fix it (e.g. port the patch), then re-run hypr-rdp/install.sh." \
        2>/dev/null
    exit 1
    ;;
esac
