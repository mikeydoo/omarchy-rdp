-- Hyprland config for the RDP remote session (the headless second session).
-- Loaded by run-headless-hyprland.sh with `Hyprland --config`; the desk keeps using
-- ~/.config/hypr/hyprland.lua. Installed by omarchy-hypr-rdp: re-running its installer
-- replaces this file (the old one is backed up), so put remote-only changes in
-- ~/.config/hypr-rdp/remote.lua instead.
--
-- It loads the same things as Omarchy's own hyprland.lua (Omarchy's defaults, then your
-- input, bindings and looknfeel), so the remote session looks and behaves like the desk.
-- What it leaves out:
--   - Omarchy's autostart (default.hypr.autostart) and yours (hypr.autostart): they
--     point the systemd user environment at this display and start desk services
--     (udiskie, herdr, monitor watch, post-boot hooks) a second time.
--   - Your monitors.lua: its rules are for the desk's screens. The remote session has
--     one virtual screen, hypr-rdp, sized to the RDP client.
--   - Anything you added at the bottom of ~/.config/hypr/hyprland.lua.

dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")

-- Stand-ins for the two autostart modules, so require() returns at once.
-- (Set after bootstrap.lua, which clears these modules on every config reload.)
package.loaded["default.hypr.autostart"] = true
package.loaded["hypr.autostart"] = true

require("default.hypr.omarchy")

require("hypr.input")
require("hypr.bindings")
require("hypr.looknfeel")

require("default.hypr.toggles")

hl.on("hyprland.start", function()
  -- This session has its own D-Bus (dbus-run-session): point the services it starts
  -- (portals, GNOME apps, ...) at this display. No --systemd: the systemd user
  -- environment belongs to the desk.
  hl.exec_cmd("dbus-update-activation-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE"
    .. " XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE DISPLAY OMARCHY_PATH PATH")
  -- The Omarchy shell (bar, notifications, launcher, lock screen) for this session.
  hl.exec_cmd("omarchy-launch-shell")
  -- No hypr-rdp here: hypr-rdp-remote.service runs it against this session.
end)

-- hypr-rdp's virtual screen at scale 1, at the size hypr-rdp gave it for the client.
-- On a config reload (a theme change rewrites the theme's Lua) keep that size rather
-- than falling back to "preferred".
local mode = "preferred"
for _, m in ipairs(hl.get_monitors()) do
  if m.name == "hypr-rdp" and m.width and m.height then mode = m.width .. "x" .. m.height end
end
hl.monitor({ output = "hypr-rdp", mode = mode, position = "0x0", scale = 1 })

-- Your own remote-only additions, if any (not touched by the installer).
local extra = os.getenv("HOME") .. "/.config/hypr-rdp/remote.lua"
local f = io.open(extra, "r")
if f then
  f:close()
  dofile(extra)
end
