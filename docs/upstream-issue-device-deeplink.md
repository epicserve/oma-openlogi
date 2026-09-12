# Upstream issue draft

Filed as https://github.com/AprilNEA/OpenLogi/issues/1375 on 2026-09-12.
The text below is what was posted.

Fill the template fields with the sections below. Facts were checked
against tag `v0.8.3` (the version packaged as `openlogi-bin` on Arch) on
2026-09-12.

---

**Title:** `[Feature]: Deep link to a specific device (openlogi://show-device/<serial>), delivered on Linux too`

**Pre-flight checklist**

- [x] I searched existing issues and the Roadmap, and this isn't already tracked.
  Closest I found: #669 (macOS battery widget), #964 (Windows tray battery), #839 (Linux "Open application" target). None cover external navigation into the GUI.

**Problem / motivation**

I'm building a small status-bar widget for Linux (Omarchy / Hyprland) that shows battery levels for the devices the agent manages, read via `openlogi list`. Each row is a device, and the natural click action is "take me to this device's page in OpenLogi". Today there is no way to do that from outside the app:

- `openlogi-desktop` takes no command-line arguments; anything passed is ignored and the GUI just starts.
- The `openlogi://` scheme (`openlogi_core::brand::DeeplinkCommand`) has five commands: `show`, `open-settings`, `open-about`, `check-for-updates`, `quit`. There is no per-device command.
- On Linux the scheme isn't reachable at all: URLs are delivered through `app.on_open_urls` in `crates/openlogi-desktop/src/main.rs`, which GPUI only fires from the macOS bundle. The shipped `openlogi.desktop` declares no `MimeType=x-scheme-handler/openlogi` and no `%u`, and a second launch stops at the `single_instance::acquire("openlogi.lock")` guard and exits without handing anything to the running instance.
- The agent's RPC (`Agent.snapshot`, `Agent.observe`, `set_dpi`, ...) drives devices, not GUI navigation, so there's no back door there either.

So the best an external tool can do is launch the app onto the home gallery, and the user still has to find the device.

**Proposed solution**

1. **A per-device deep-link command.** Add a variant to `DeeplinkCommand` that carries a device identifier, e.g. `openlogi://show-device/<id>` (or `openlogi://show?device=<id>`). Dispatch would `main_window::ensure` and then select that device's detail view, the same thing a click on its home card does. For the identifier, the device serial (`serial=` in `openlogi list`, already the basis of the GUI's config key) is stable across slots and receivers; `unit_id` or `wpid+slot` could be accepted as fallbacks for serial-less devices. Unknown or offline ids could just open home.

2. **Deliver the scheme on Linux.** Add `MimeType=x-scheme-handler/openlogi;` and `Exec=openlogi-desktop %u` to `openlogi.desktop` so `xdg-open openlogi://...` resolves. When the single-instance lock is already held, forward the URL(s) to the running instance before exiting instead of dropping them. The GUI already keeps a connection to the agent, so one option is a tiny relay RPC on the agent (`Agent.open_url` → pushed to GUI clients over the existing observe stream); another is a small local socket owned by the GUI next to its lock file. Either would also make the existing `show` / `open-settings` commands usable on Linux, which the agent's tray presumably wants too (#839 is adjacent).

3. **Optional, cheapest first step:** accept the same command as a CLI argument, `openlogi-desktop --url openlogi://show-device/<id>` (or `openlogi-desktop <url>`), and have the second-instance path forward it. That covers Linux without touching MIME registration and gives Windows the same entry point.

I'm happy to send a PR for (1) and (3) if the shape sounds right; I'd want a nod on the identifier and the forwarding mechanism first.

**Alternatives considered**

- Launching `openlogi-desktop` and letting the user click the device: works, but it's the click this request is trying to remove.
- Pre-seeding a "last selected device" in `config.toml` before launch: the app doesn't persist one (`main_window::open(&[], cx)` starts from an empty selection), and it wouldn't help when the app is already running.
- Talking to the agent socket directly: nothing there addresses the GUI.
- Logi Options+ has no external navigation either, so there's no prior art to match; this is a small gap that only shows up once other tools start integrating with OpenLogi, which is exactly what the CLI and local-first design invite.

**Related area(s)**

- [x] GUI
- [x] CLI
- [x] Other (Linux desktop integration / URL scheme)

**Additional context**

- Widget this is for: an Omarchy bar plugin that polls `openlogi list` (stdout tree, provenance on stderr, exit 2 for "nothing found" all behaved as documented in `list.rs`, thanks for that) and renders a battery row per device. Source: https://github.com/epicserve/oma-openlogi
- Versions: OpenLogi 0.8.3 (`openlogi-bin` AUR), Arch Linux, Hyprland/Omarchy, agent as a `systemd --user` service.
- Relevant code paths at v0.8.3: `crates/openlogi-core/src/brand.rs` (`DeeplinkCommand`), `crates/openlogi-desktop/src/app/deeplink.rs` (dispatch), `crates/openlogi-desktop/src/main.rs` (`on_open_urls`, single-instance guard), `crates/openlogi-desktop/src/windows/main_window.rs` (`open(&[], cx)`), `crates/openlogi-desktop/src/state/devices.rs` (`config_key` / serial).
