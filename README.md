# omarchy-hypr-rdp

An Omarchy plugin for a second, **headless** Hyprland session you reach over RDP, separate
from the session at the desk: same user, same config, its own windows. One of the two is in
use at a time; the newest login wins.

> **Work in progress.** Being ported from a CachyOS/DMS setup to Omarchy. Not ready to use.

## How it works

```
RDP client ──► :3389  rdp-gate.py   (always listening; newest connection wins;
                        │             cuts RDP the moment the desk session is unlocked)
                        ▼
               127.0.0.1:3390  hypr-rdp  (PAM login; on login locks the desk)
                        ▼
               headless Hyprland  (hyprland-remote.service: patched libaquamarine,
                                   own D-Bus, Omarchy's config without its desk autostart)
```

Hyprland can't run with only headless screens and no seat: aquamarine's headless backend has
no GPU device. `files/local/share/hyprland-headless/patches/` holds a small opt-in patch
(`AQ_HEADLESS_RENDER_NODE=/dev/dri/renderD128`) that is built into a private copy of
libaquamarine for the remote session only; the system library is untouched.

Stock Omarchy is left as it is: nothing in `/usr/share/omarchy`, `~/.config/hypr` or SDDM is
changed. Everything is added in its own files.

## Plan

The plugin will install, check and manage everything:

- install: `omarchy plugin add https://github.com/mikeydoo/omarchy-hypr-rdp --enable`,
  then **Set up** from its bar icon
- health checks with fixes, rebuilding the patched libaquamarine after aquamarine updates
- status (remote session, connected client, port) and controls (log out, disconnect, port)
