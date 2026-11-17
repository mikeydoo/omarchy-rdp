# Omarchy RDP

An Omarchy plugin (`omarchy-rdp`) for a second, **headless** Hyprland session you reach over RDP, separate
from the session at the desk: same user, same Omarchy config, its own windows. One of the
two is in use at a time; the newest login wins. Set it up, check it and manage it from the
bar.

> **Status:** early (0.1). Developed and tested on Omarchy 4.5 (Hyprland 0.56.2,
> aquamarine 0.15.1) in a Proxmox VM.

## Install

```
omarchy plugin add https://github.com/mikeydoo/omarchy-rdp --enable
```

Then click the remote-desktop icon in the bar and choose **Set up**. A terminal opens and
runs the installer (it builds `hypr-rdp` from the AUR and asks for your password for the
packages, lingering and the firewall). Re-run it any time from **Repair**.

Connect from any RDP client to `<this machine>:3389` and log in with your Linux user and
password. FreeRDP:

```
xfreerdp3 /v:<host> /u:$USER /sec:tls /cert:ignore /dynamic-resolution
```

Login needs TLS security without NLA. Windows `mstsc` may need the credentials saved in
Credential Manager. The certificate is self-signed (in `~/.config/hypr-rdp`).

## What happens when

| You... | Result |
|---|---|
| Log in over RDP | The desk locks (Omarchy's own lock). |
| ...and the desk was used since your last RDP login | The remote session asks: log out the desk session, or keep it. |
| Unlock the desk | The RDP client is cut within about a second. |
| ...and the remote session was used since | The desk asks: log out the remote session, or keep it. |
| Connect a second RDP client | It takes over; the first is cut. |
| Log out in the remote session (Omarchy menu) | The remote session ends; the next RDP login starts a fresh one. |
| Reboot | The remote session and RDP start at boot (lingering); the desk logs in as usual. |

Windows can't move between the two sessions (a Wayland window belongs to one compositor).

## The panel

- **State icon:** dim = not set up / RDP off, normal = ready or connected, red = needs
  attention.
- **Accept RDP connections** switch: starts or stops the listener on port 3389.
- **Connect:** the FreeRDP command for this machine, with a copy button.
- **Remote session:** running / locked / not running, and *Disconnect client*, *Restart*,
  *Log out* (two clicks). In the remote session itself: *Log out desk session*.
- **Checks:** everything the setup needs, each problem with a **Fix** button.
- **Update** (pull the plugin and re-install), **Repair**, **Uninstall**.
- Settings (bar widget settings): *Lock the remote session on its first start* (off: RDP
  already asks for your password) and *Rebuild after aquamarine updates* (on).

Everything the panel does goes through `bin/omarchy-rdp-ctl`, which works the same from a
shell (`omarchy-rdp-ctl status`, `omarchy-rdp-ctl --help`).

## How it works

```
RDP client ──► :3389  rdp-gate.py   (rdp-gate.service, always listening; newest connection
                        │             wins; cuts RDP the moment the desk is unlocked)
                        ▼
               127.0.0.1:3390  hypr-rdp  (hypr-rdp-remote.service; PAM login; sizes a
                        │                 virtual screen to the client; locks the desk)
                        ▼
               headless Hyprland  (hyprland-remote.service, run-headless-hyprland.sh)
                 patched libaquamarine, own D-Bus, ~/.config/hypr-rdp/hyprland-remote.lua
```

- **Hyprland with no seat.** Hyprland can't run with only headless screens: aquamarine's
  headless backend has no GPU device. A small opt-in patch
  (`files/local/share/hyprland-headless/patches/`) makes it use a render node when
  `AQ_HEADLESS_RENDER_NODE` is set. It's built into a private copy of libaquamarine for the
  remote session only; the system library is untouched. It's rebuilt automatically when
  aquamarine changes (before the remote session starts, and by the plugin right after an
  update).
- **Omarchy's config, without the desk's autostart.** `hyprland-remote.lua` loads Omarchy's
  defaults and your `input`, `bindings` and `looknfeel`, with Omarchy's autostart stubbed
  out (it would point the systemd environment at the remote screen and start desk services
  twice), then starts the Omarchy shell. Remote-only additions go in
  `~/.config/hypr-rdp/remote.lua`.
- **Apps open where you are.** Omarchy starts apps through `uwsm-app`, which uses the desk's
  environment. The remote session has its own `uwsm-app` and `uwsm` first on its `PATH`:
  apps run directly in the remote session, and Log Out ends the remote session, not the
  desk.
- **Locking** uses Omarchy's lock screen through `omarchy-shell`, pointed at the right
  session (Omarchy's lock doesn't report to logind).

## What it adds to the system

Stock Omarchy is left as it is: nothing in `/usr/share/omarchy`, `~/.config/hypr`, your
`~/.config/omarchy` settings or SDDM is changed (besides the plugin itself and its bar
entry, which `omarchy plugin add` manages).

| Added | Where |
|---|---|
| `hypr-rdp` (AUR), `cmake`, `hyprwayland-scanner` | packages |
| launcher, patched libaquamarine, `uwsm`/`uwsm-app` stand-ins | `~/.local/share/hyprland-headless/` |
| scripts, `config.toml`, `hyprland-remote.lua` | `~/.config/hypr-rdp/` |
| `hyprland-remote`, `hypr-rdp-remote`, `rdp-gate` | `~/.config/systemd/user/` |
| lingering | `loginctl enable-linger` |
| TCP 3389 from your LAN only (comment `omarchy-rdp`) | UFW |

Replaced files are backed up to `~/.local/state/omarchy-rdp/backup-<date>/`.
`config.toml` is only installed when missing, so your edits stay.

## Requirements and hardware notes

- A GPU render node (`/dev/dri/renderD*`). In a Proxmox/QEMU VM set the display to
  **VirGL GPU (virtio-gl)**.
- Hardware H.264 needs a VA-API driver with encode support (AMD, Intel). `config.toml` uses
  `clearcodec` (lossless, damage-only) by default, which needs no video encoder.
- The virtual screen follows the client's size, up to 3840x2160.

## Limitations

- Same user in two sessions: a browser can't open the same profile in both at once (use a
  second profile remotely); the desk's keyring isn't visible to remote apps.
- Reboot and Shut Down in the remote session act on the whole machine.
- Omarchy's idle settings (`shell.json`) apply to both sessions: a remote session left
  disconnected locks after your idle timeout, and the stay-awake toggle is shared.
- The newest connection wins before authentication: a client with a wrong password still
  cuts the current RDP session.
- Apps in the remote session don't get their own systemd scopes.

## Troubleshooting

| Symptom | Fix |
|---|---|
| RDP connects, then drops at once | `journalctl --user -u rdp-gate -u hypr-rdp-remote -u hyprland-remote -n 50` |
| Panel shows the patch needs porting | aquamarine changed too much for the patch: port `patches/aquamarine-headless-render-node.patch`, then **Repair** |
| Desk login: uwsm "A compositor or graphical-session* target is already active!" | `systemctl --user stop graphical-session.target`, log in again |

## Uninstall

**Uninstall** in the panel (or `omarchy-rdp-ctl uninstall`) removes the services, files and
firewall rule, and backs up `config.toml`. Then:

```
omarchy plugin remove mikeydoo.omarchy-rdp
sudo loginctl disable-linger "$USER"   # if nothing else needs it
sudo pacman -R hypr-rdp                # optional
```

## Licence

MIT
