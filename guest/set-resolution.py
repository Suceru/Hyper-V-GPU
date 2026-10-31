#!/usr/bin/env python3
"""Set GNOME (Mutter Wayland) output mode to 1920x1080@60 on the Hyper-V Virtual-1 connector.

Uses org.gnome.Mutter.DisplayConfig:
  ApplyMonitorsConfig(u serial, u method, a(iiduba(ssa{sv})) logical_monitors, a{sv} properties)
method=2 -> persistent (also writes ~/.config/monitors.xml)
"""
import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

connector = "Virtual-1"
target_w, target_h = 1920, 1080

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
proxy = Gio.DBusProxy.new_sync(
    bus, Gio.DBusProxyFlags.NONE, None,
    "org.gnome.Mutter.DisplayConfig",
    "/org/gnome/Mutter/DisplayConfig",
    "org.gnome.Mutter.DisplayConfig", None,
)

state = proxy.call_sync("GetCurrentState", None, Gio.DBusCallFlags.NONE, -1, None)
serial, monitors, logical, props = state.unpack()

mode_id = None
for mon in monitors:
    spec = mon[0]
    if spec[0] != connector:
        continue
    for m in mon[1]:
        mid, w, h = m[0], int(m[1]), int(m[2])
        if w == target_w and h == target_h:
            mode_id = mid
            break
if not mode_id:
    raise SystemExit(f"mode {target_w}x{target_h} not found on {connector}")

print(f"applying {connector} -> {mode_id}")
logical_monitor = (0, 0, 1.0, 0, True, [(connector, mode_id, {})])
args = GLib.Variant(
    "(uua(iiduba(ssa{sv}))a{sv})",
    (int(serial), 2, [logical_monitor], {}),
)
proxy.call_sync("ApplyMonitorsConfig", args, Gio.DBusCallFlags.NONE, -1, None)
print("applied OK")
