# brent.openlogi-battery

An [Omarchy](https://omarchy.org) bar widget that shows battery levels for
Logitech devices managed by [OpenLogi](https://github.com/AprilNEA/OpenLogi),
with a button through to the full OpenLogi app for everything else.

## What it does

- Bar icon: a battery glyph for the lowest battery among online devices,
  using the same ten-step glyph set as Omarchy's own power widget. Turns
  the theme's urgent color at or below the low-battery threshold, and
  shows a battery-alert glyph when the OpenLogi agent isn't running.
- Click: a popover with one row per paired device (kind, name, charging /
  offline / level, percentage) and an **Open OpenLogi** button.
- Right-click the icon, or press `r` in the popover, to refresh now.
- Hidden entirely when the agent is fine and nothing is paired.

Battery data comes from `openlogi list`, read from the running
`openlogi-agent`. The widget never opens HID devices itself.

## Requirements

- Omarchy with the Quickshell-based shell (`omarchy-shell`).
- `openlogi-bin` (AUR) with `openlogi-agent.service` enabled as a user
  service: `systemctl --user enable --now openlogi-agent`.
- `uwsm-app` (ships with Omarchy) to launch the desktop app in its own
  systemd scope.

## Install

```bash
git clone https://github.com/epicserve/oma-openlogi ~/Code/personal/oma-openlogi
~/Code/personal/oma-openlogi/install.sh
```

`install.sh` symlinks the repo into `~/.config/omarchy/plugins/`,
validates the manifest, rescans plugins, and enables the widget to the
left of the Bluetooth icon. Move it afterwards with
`omarchy bar move brent.openlogi-battery --after omarchy.tray` or by
editing `~/.config/omarchy/shell.json`.

## Settings

Set per widget in `~/.config/omarchy/shell.json`, or with
`omarchy bar set brent.openlogi-battery <key> <value>`:

| Key | Default | Meaning |
|---|---|---|
| `pollIntervalSec` | `300` | How often to re-run `openlogi list` while the popover is closed. Every 30 s while it is open. |
| `lowBatteryThreshold` | `20` | Percent at or below which a device's row and the bar icon switch to the urgent color. Charging devices never count as low. |

## IPC

```bash
omarchy-shell brent.openlogi-battery toggle    # open/close the popover
omarchy-shell brent.openlogi-battery refresh   # poll now
omarchy-shell brent.openlogi-battery launch    # open the OpenLogi app
omarchy-shell brent.openlogi-battery status    # JSON: devices, agent state, lowest battery
```

## States

| Bar icon | Meaning |
|---|---|
| Battery glyph | Lowest online battery. Charging variant if that device is charging. |
| Battery glyph, urgent color | Some online, non-charging device is at or below the threshold. |
| Battery-alert glyph, urgent color | Nothing is listening on the agent socket. The popover suggests `systemctl --user restart openlogi-agent`. |
| Battery-unknown glyph | Devices are paired but none reports a percentage. |
| Hidden | Agent is up and nothing is paired, or no receiver is plugged in. |

If a poll fails or the output can't be parsed, the last good device list
stays on screen dimmed, with the reason in the popover.

## Development

```bash
node --test test/       # Model.js parser tests against test/fixtures
omarchy plugin validate ~/Code/personal/oma-openlogi
```

The shell's plugin watcher does not follow the symlink into this repo, so
run `bin/dev-watch` to rescan on every save, or call
`omarchy-shell shell rescanPlugins` by hand. `Service.qml` edits are
cached by the QML engine and need `omarchy restart shell`; check which
code is loaded with the `serviceRevision` field in the IPC `status`.

`Model.js` is pure JavaScript with no QML dependencies so it runs under
node; the `openlogi list` output shapes it handles are documented in
`plan.md` and exercised by the fixtures.

## Known limitations

- `openlogi list` has no machine-readable output, so the widget parses
  its tree-formatted text. A format change upstream shows up as a
  "couldn't parse" warning rather than an empty widget; the raw output
  is logged by `omarchy-shell`.
- Battery values are whatever the agent last read from the device.
  Devices asleep or out of range show as offline and are excluded from
  the bar icon.
- Keyboard backlight control (`openlogi backlight`) isn't exposed yet.
  See `plan.md`, Future work.

## License

MIT
