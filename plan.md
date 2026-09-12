# oma-openlogi: Omarchy bar widget plan

A third-party Omarchy shell plugin (`kind: bar-widget`) that shows battery
levels for Logitech devices connected through OpenLogi, with a button to
open the OpenLogi desktop app for everything else (DPI, remaps, lighting).

## Why

- Solaar has been fully removed from this machine (see `~/.dotfiles`
  commit "Replace Solaar with OpenLogi for Logitech device management").
  OpenLogi (`openlogi-bin`, AUR) now owns the Logi Bolt receiver via
  `openlogi-agent.service`.
- OpenLogi's own desktop GUI has no bar/tray presence and no compact
  "glance and go" battery view — you have to open the full app window to
  see anything. That's the same complaint that got Solaar dropped.
- OpenLogi's GUI also has no keyboard-backlight panel (see Known
  limitations below): the CLI's `openlogi backlight` command works, but
  nothing in the desktop app calls it. This widget's popover is a natural
  place to put a backlight toggle later, once the base battery widget is
  proven out.

## What ships

An Omarchy bar-widget plugin at `~/.config/omarchy/plugins/<id>/` with:

- A bar icon that shows the lowest battery level across *online*
  Logitech devices as a battery glyph (the same ten-step glyph set
  `omarchy.power` uses), switching to the urgent color at or below the
  low-battery threshold, and to a battery-alert glyph when the agent is
  down.
- A click popover listing every paired device with name, kind icon,
  battery percentage, and charging / offline state.
- A footer button ("Open OpenLogi") that launches `openlogi-desktop`.
- A background poll of `openlogi list` on an interval, parsed into a
  small device list, with last-good data kept across flaky reads.
- An IPC target (`brent.openlogi-battery`) with `refresh()`, `status()`
  (JSON) and `launch()` so scripts and a future low-battery hook can use
  the same data.

Out of scope for v1 (explicitly deferred, not forgotten):

- Keyboard backlight control (on/off, level) via `openlogi backlight`.
  Add once the base widget is stable; see Future work.
- DPI, SmartShift, remaps -- these already work in the OpenLogi desktop
  app; no reason to duplicate them here.
- Low-battery notifications. The built-in battery service calls
  `omarchy-battery-low <level>`, which runs
  `~/.config/omarchy/hooks/battery-low.d/`; a peripheral equivalent can
  be added later, but it's a separate feature from "show me the battery."

## Ground truth this plan is built on

Checked on this machine (2026-09-12), `openlogi 0.8.3` installed via
`~/.dotfiles/setup_omarchy.sh`, `openlogi-agent.service` enabled. The
output format below was cross-checked against upstream
`crates/openlogi-cli/src/cmd/list.rs` at tag `v0.8.3`.

```
$ openlogi list
(inventory read from the running agent)                      <- stderr
Logi Bolt Receiver (0123456789ABCDEF, vid=046d pid=c548)     <- stdout from here
  ├─ slot 3 ● MX MCHNCL M (keyboard, wpid=b367, battery=95% full (discharging))
  │       model_ids=[b367,0000,0000] ext=00 serial=2201ABC0DEF1 unit_id=00aa11bb transports=btle
  └─ slot 4 ● MX Master 4 (mouse, wpid=b042, battery=85% full (discharging))
          model_ids=[b042,0000,0000] ext=00 serial=2502XYZ0GHI2 unit_id=22cc33dd transports=btle
```

Key facts that shape the design:

- **No `--json` flag exists** (still true at the latest upstream
  release, v0.8.3). The widget parses the tree-formatted stdout.
- **The provenance header goes to stderr**, deliberately, "so scripts
  keep parsing stdout". `(inventory read from the running agent)` means
  the agent answered; `(no agent reachable — reading hardware directly
  ...)` means the CLI fell back to its own HID++ enumeration. The widget
  must collect stderr separately; that line is the agent-liveness
  signal, so no separate `systemctl` probe is needed.
- **Exit codes**: `0` = enumeration succeeded (device lines follow, or a
  receiver with `└─ no paired devices`); `2` = "No Logitech HID++
  devices or webcams found." plus a Notes block (not an error); anything
  else = enumeration failed.
- **Agent timeouts**: the CLI waits up to 2 s to connect, 2 s to declare
  itself, 5 s for the snapshot, and only then falls back to direct
  enumeration (which itself can take seconds). With the agent up, a call
  returns in ~2 ms. The poll must never overlap itself and needs a
  watchdog.
- **The fallback path opens `/dev/hidraw*` from the CLI process.** The
  widget avoids triggering it by checking, with `ss`, that something is
  listening on `$XDG_RUNTIME_DIR/openlogi/agent.sock` before running
  `openlogi list`, and reporting "agent down" itself (exit 3 from the
  wrapper) otherwise. A plain file test is not enough: the socket file
  survives `systemctl --user stop openlogi-agent` (verified), and against
  that stale socket the CLI silently falls back to a direct read and
  still exits 0. Never talk HID++ from the widget directly.
- **The agent's inventory flaps.** The journal shows bursts of
  `paired-device count mismatch`, retired channels and gesture capture
  re-arms within a ~45 s window. A single bad read must not blank the
  widget for a whole poll interval: keep the last-good device list and
  mark it stale, the way `omarchy.power`'s `updateKeyValue` ignores an
  empty payload.
- **`openlogi-desktop` is the GUI binary** (`/usr/bin/openlogi-desktop`,
  desktop entry `openlogi.desktop`, app id `org.openlogi.openlogi`).
- **The agent also exposes a tarpc socket** at
  `$XDG_RUNTIME_DIR/openlogi/agent.sock` with `Agent.inventory`,
  `Agent.observe` and friends. It is protocol-versioned and undocumented,
  so v1 does not use it; see Future work.
- **The keyboard backlight feature (`0x1982`, BACKLIGHT2 v2)** has no GUI
  in OpenLogi, only `openlogi backlight [--device <substring>]
  [status|off|on]`. Level/duration control needs firmware 72.3.14+ (via
  Logi Options+ on macOS/Windows) regardless of what any Linux tool does.

## Parsing `openlogi list`

All shapes the parser must handle (from upstream's own format tests):

| Shape | Example |
|---|---|
| Receiver header | `Logi Bolt Receiver (0123456789ABCDEF, vid=046d pid=c548)` (uid may be `—`) |
| Online device | `  ├─ slot 3 ● MX MCHNCL M (keyboard, wpid=b367, battery=95% full (discharging))` |
| Offline device | `  └─ slot 1 ○ MX Master 3S (mouse, wpid=4082, battery=—)` |
| No battery info | `battery=—` (em dash, the segment is never absent) |
| Unknown identity | `slot 1 ● Unknown device (mouse, wpid=?, battery=—)` |
| Battery status | lowercased Rust `Debug` names: `discharging`, `charging`, `chargingslow`, ... |
| Battery level | `full`, `good`, `low`, `critical` |
| Continuation line | `  │       model_ids=[...] ext=00 serial=2201ABC0DEF1 unit_id=... transports=btle` (serial may be `—`) |
| Empty receiver | `  └─ no paired devices` |
| Logitech webcam block | `Cameras (1 Logitech UVC)` then `  ├─ ● Name (camera, vid=... id=...)` |
| Nothing at all | `No Logitech HID++ devices or webcams found.` + `Notes:` lines, exit 2 |

`Model.js` (pure, unit-testable with node):

1. `parseDeviceList(stdout)` → `{ devices, receivers, noPaired,
   nothingFound, hasCameras, parseMiss }`. Device lines are matched by a
   regex anchored on `slot N` (camera lines have no slot and are
   skipped). Each device: `{ slot, online, name, kind, wpid, battery
   (int|null), level, status, charging, serial, transports, receiver }`.
   The continuation line attaches `serial` / `transports` to the device
   just parsed.
2. `parseMiss` is true when stdout is non-empty, no device parsed, no
   "no paired devices" line, not the exit-2 "nothing found" text, and
   not a cameras-only listing. The Panel shows it as a warning so an
   OpenLogi format change never looks like "no devices".
3. `agentStateFromStderr(stderr)` → `"agent" | "direct" | "unknown"`.
4. `lowestBattery(devices)` ignores offline devices and devices with no
   battery; `batteryIcon(percent, charging)` reuses the glyph arrays
   from `omarchy.power/Model.js`; `kindIcon(kind)` maps mouse / keyboard
   / other.
5. This parsing layer is the one thing most likely to break on an
   OpenLogi upgrade. Fixtures (stdout + stderr + exit code) live in
   `test/fixtures/` and `test/model.test.js` runs under node.

## Service states

`Service.qml` exposes plain properties; the Panel stays presentation-only.

| State | How it's detected | What the widget does |
|---|---|---|
| Normal | exit 0, devices parsed, stderr says agent | Show devices, lowest-battery icon |
| Receiver present, nothing paired | exit 0 + `no paired devices` | Hide the bar icon |
| Nothing found | exit 2 | Hide the bar icon |
| Agent down | wrapper exit 3 (nothing listening on the socket) or stderr `no agent reachable` | Battery-alert glyph in urgent color; popover explains and suggests `systemctl --user restart openlogi-agent`; keep last-good list, marked stale |
| Read failed | other exit code, or watchdog kill | Keep last-good list, show `lastError`, mark stale |
| Parse miss | exit 0 but nothing matched | Keep last-good list, show a "format changed" warning |

Polling: a `Timer` at `pollIntervalSec` while closed, every 30 s while
the popover is open, plus an immediate refresh on open. Right-click on
the bar icon forces a refresh. A single `Process` guarded by `running`
plus a 20 s watchdog that kills a stuck poll.

Poll command (one process, no fallback into direct HID access):

```
bash -c 'sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/openlogi/agent.sock";
         ss -xlH "src $sock" | grep -q . || { echo "no listener on $sock" >&2; exit 3; };
         exec openlogi list'
```

(With `ss` unavailable it degrades to the `-S` file test.)

## Reference: existing local plugin (`brent.insta360`) and built-ins

`~/.config/omarchy/plugins/brent.insta360` (source at
`~/Code/personal/omainstacam`) is the structural template: `Panel.qml`,
`Service.qml`, `Model.js`, `manifest.json`, `README.md`, `install.sh`.
Copy its skeleton, its `Process` + `StdioCollector` pattern, its
`IpcHandler` with `manageIpc: false`, and its keyboard cursor
(`cursorActive` / `focusSection` / `hasCursor`). Skip the camera bits.

Reuse from `/usr/share/omarchy/shell` rather than inventing:

- `plugins/panels/power/Model.js`: the `defaultIcons` / `chargingIcons`
  ten-step battery glyph arrays.
- `plugins/panels/bluetooth/Panel.qml`: the device row (`CursorSurface`
  with kind icon, name, caption, right-aligned status text).
- `qs.Ui`: `Panel` (has `setting()` built in), `BarIconButton`,
  `KeyboardPanel`, `PanelKeyCatcher`, `PanelHero`, `PanelSeparator`,
  `PanelSectionHeader`, `Button`, `CursorSurface`.
- Launching the GUI: `Quickshell.execDetached(["uwsm-app", "--",
  "openlogi-desktop"])`, as `plugins/panels/dropbox/Service.qml` does for
  nautilus, so the app gets its own systemd scope and survives a shell
  restart.

## Plugin manifest

```json
{
  "schemaVersion": 1,
  "id": "brent.openlogi-battery",
  "name": "OpenLogi Battery",
  "version": "0.1.0",
  "author": "Brent O'Connor",
  "license": "MIT",
  "description": "Battery levels for Logitech devices managed by OpenLogi, with one click through to the full app.",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "Panel.qml" },
  "barWidget": {
    "displayName": "OpenLogi Battery",
    "description": "Battery levels for paired Logitech devices, with a button to open OpenLogi.",
    "category": "Hardware",
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": { "pollIntervalSec": 300, "lowBatteryThreshold": 20 },
    "schema": [
      { "key": "pollIntervalSec", "type": "integer", "label": "Poll interval (seconds)", "min": 30, "max": 1800, "step": 30, "defaultValue": 300 },
      { "key": "lowBatteryThreshold", "type": "integer", "label": "Low battery warning threshold (%)", "min": 0, "max": 100, "step": 5, "defaultValue": 20 }
    ]
  }
}
```

The same manifest shape (including `"category": "Hardware"` and integer
schema entries) passes `omarchy plugin validate` for `brent.insta360`.

## File layout

```
~/Code/personal/oma-openlogi/          (symlinked to ~/.config/omarchy/plugins/brent.openlogi-battery)
├── manifest.json
├── Panel.qml        # Bar icon + popover UI
├── Service.qml      # Polling, watchdog, state machine
├── Model.js         # Pure functions: parse, icons, formatting
├── install.sh       # symlink + validate + enable (copied from insta360)
├── README.md
├── plan.md          # this file
└── test/
    ├── model.test.js
    └── fixtures/    # captured stdout/stderr per state
```

## Bar icon and popover design

- **Icon**: battery glyph for the lowest online battery; charging
  variant if that device is charging; `Color.urgent` / `bar.urgent` at
  or below `lowBatteryThreshold`; battery-alert glyph in urgent color
  when the agent is down; battery-unknown glyph if devices exist but
  none reports a battery.
- **Visibility**: shown when at least one device is known, or the agent
  is down, or a parse miss needs surfacing. Hidden (zero width, like
  `omarchy.power` with no battery) when the agent is fine and nothing is
  paired.
- **Popover**: `PanelHero` (title "OpenLogi", meta = summary line such
  as "2 devices · lowest 85%" or "Agent not running"), one row per
  device (kind icon, name, caption with charging / offline / level,
  right-aligned percentage colored urgent when low), an explanatory
  block for the agent-down / parse-miss / error states, a
  `PanelSeparator`, and a footer `Button` "Open OpenLogi" that launches
  the GUI and closes the popover. Right-click the icon or press `r` in
  the popover to refresh.
- **Keyboard**: cursor walks device rows then the footer button; Enter
  on the button launches; Esc closes; Tab switches panels.

## Settings

Exposed via the manifest `schema` (ends up in `~/.config/omarchy/shell.json`
under this widget's bar entry):

| Key | Default | Meaning |
|---|---|---|
| `pollIntervalSec` | `300` | How often to re-run `openlogi list` while the popover is closed. |
| `lowBatteryThreshold` | `20` | Percent at or below which a device's row and the bar icon switch to the urgent color. |

## Build order

1. `Model.js` + node tests against fixtures for every row of the shapes
   table above, plus stderr / exit-code classification. Front-loaded
   because it's the riskiest part.
2. Scaffold `manifest.json`, `Service.qml`, `Panel.qml`; `install.sh`
   symlinks the repo, runs `omarchy plugin validate` against the real
   path (the validator refuses symlinks), `omarchy-shell shell
   rescanPlugins`, and `omarchy plugin enable brent.openlogi-battery
   right --before omarchy.bluetooth`.
3. Wire the real poll, verify all states by hand: normal, `systemctl
   --user stop openlogi-agent` (agent down), receiver unplugged (if
   practical), and a deliberately broken regex (parse miss). Note the
   shell's watcher doesn't follow the plugin symlink and the QML engine
   caches `Service.qml`, so after editing it run `omarchy restart shell`
   and confirm via the `serviceRevision` field in IPC `status`.
4. Polish: theme colors, keyboard nav, README (what it does,
   requirements, install, settings, known limitations, IPC).

## Future work (explicitly not v1)

- **Keyboard backlight control.** A toggle (and, once firmware 72.3.14
  is installed via Options+, a brightness slider) in the popover calling
  `openlogi backlight --device <name> on|off`. Upstream shipped backlight
  as CLI-only with no GUI panel as of 2026-09-12.
- **Push updates instead of polling** via the agent's tarpc socket
  (`Agent.observe`), once the protocol is documented or stable enough to
  depend on. Would need a small helper binary; QML can't speak tarpc.
- **Low-battery notification hook** for peripherals, reusing the
  `battery-low.d` hook directory pattern and the widget's IPC `status()`.
- **DPI quick-actions** only if the GUI round-trip proves annoying.
