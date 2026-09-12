import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the poll of `openlogi list` and the state derived from it. The Panel
// is presentation-only and reads the plain properties below.
//
// Facts that shape this file (see plan.md, "Ground truth"):
//  - the provenance header goes to stderr, stdout is the device tree only;
//  - exit 2 means "no hardware", not failure;
//  - with no agent the CLI waits up to ~9 s and then enumerates HID++ itself,
//    so we test for the agent socket first and never trigger that path;
//  - the agent's inventory flaps, so a bad read keeps the last good list.
Item {
  id: root

  property var settings: ({})
  // Bound by the Panel so polling speeds up while the popup is on screen.
  property bool opened: false

  // Parsed device rows, last known good. See Model.parseDeviceList.
  property var devices: []
  property var receivers: []
  // "agent" | "direct" | "down" | "unknown"
  property string agentState: "unknown"
  readonly property bool agentDown: agentState === "down" || agentState === "direct"
  // exit 2, or a receiver with nothing paired: genuinely no devices.
  property bool noHardware: false
  // stdout looked like nothing we understand — OpenLogi format changed?
  property bool parseFailed: false
  property string lastError: ""
  property bool everPolled: false
  // The last poll did not replace `devices` (error / agent down / parse miss).
  property bool stale: false
  property double lastUpdatedMs: 0

  readonly property bool busy: pollProcess.running
  readonly property int pollIntervalSec: intSetting("pollIntervalSec", 300, 30, 1800)
  readonly property int lowBatteryThreshold: intSetting("lowBatteryThreshold", 20, 0, 100)

  readonly property var lowestDevice: Model.lowestDevice(devices)
  readonly property int lowestBattery: Model.lowestBattery(devices)
  readonly property bool anyLow: Model.anyLow(devices, lowBatteryThreshold)
  readonly property bool hasDevices: devices.length > 0

  // Wrapper: refuse to run `openlogi list` unless something is listening on
  // the agent socket. The socket file outlives a stopped or crashed agent, so
  // a plain -S test is not enough; `ss` reports actual listeners. Exit 3 is
  // ours; the CLI itself uses 0 (ok), 2 (nothing found) and 1 (error).
  readonly property var pollCommand: ["bash", "-c",
    'sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/openlogi/agent.sock"; '
    + 'if command -v ss >/dev/null 2>&1; then ss -xlH "src $sock" 2>/dev/null | grep -q . || { echo "no listener on $sock" >&2; exit 3; }; '
    + 'else [ -S "$sock" ] || { echo "agent socket missing: $sock" >&2; exit 3; }; fi; '
    + 'exec openlogi list']

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    return Model.clamp(Model.toInt(setting(name, fallback), fallback), min, max)
  }

  function refresh() {
    if (pollProcess.running) return
    pollProcess.command = pollCommand
    pollProcess.running = true
    watchdog.restart()
  }

  function applyResult(exitCode, stdout, stderr) {
    everPolled = true
    var err = String(stderr || "").trim()
    var provenance = Model.agentStateFromStderr(err)

    if (exitCode === 3) {
      agentState = "down"
      lastError = ""
      stale = hasDevices
      return
    }

    if (exitCode === 2) {
      // Nothing found. Trust it: the agent answered and has no receiver.
      agentState = provenance === "unknown" ? "agent" : provenance
      devices = []
      receivers = []
      noHardware = true
      parseFailed = false
      lastError = ""
      stale = false
      lastUpdatedMs = Date.now()
      return
    }

    if (exitCode !== 0) {
      agentState = provenance === "direct" ? "direct" : agentState
      lastError = err !== "" ? lastProvenanceStripped(err) : "openlogi list failed (exit " + exitCode + ")"
      stale = hasDevices
      return
    }

    var parsed = Model.parseDeviceList(stdout)
    agentState = provenance === "unknown" ? "agent" : provenance
    if (parsed.parseMiss) {
      parseFailed = true
      lastError = ""
      stale = hasDevices
      console.warn("epicserve.openlogi-battery: could not parse `openlogi list` output:\n" + String(stdout || "").slice(0, 600))
      return
    }

    devices = parsed.devices
    receivers = parsed.receivers
    noHardware = parsed.devices.length === 0
    parseFailed = false
    lastError = ""
    stale = false
    lastUpdatedMs = Date.now()
  }

  // stderr carries the provenance line plus any real error; hide the former.
  function lastProvenanceStripped(text) {
    var lines = String(text || "").split("\n")
    var keep = []
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i].trim()
      if (l === "" || /^\((inventory read|no agent reachable)/.test(l) || /^note: the agent speaks/.test(l)) continue
      keep.push(l)
    }
    return keep.join(" ").slice(0, 200)
  }

  function openApp() {
    // uwsm-app gives the GUI its own systemd scope so it outlives shell restarts.
    Quickshell.execDetached(["uwsm-app", "--", "openlogi-desktop"])
  }

  function statusJson() {
    return JSON.stringify({
      serviceRevision: 2,
      agentState: agentState,
      agentDown: agentDown,
      stale: stale,
      parseFailed: parseFailed,
      lastError: lastError,
      lastUpdated: lastUpdatedMs > 0 ? new Date(lastUpdatedMs).toISOString() : "",
      lowestBattery: lowestBattery,
      anyLow: anyLow,
      threshold: lowBatteryThreshold,
      devices: devices
    })
  }

  onOpenedChanged: if (opened) refresh()

  Timer {
    id: pollTimer
    interval: root.opened ? 30000 : root.pollIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A poll that outlives this is stuck (agent hung mid-handshake); kill it
  // so the next tick can try again rather than the guard blocking forever.
  Timer {
    id: watchdog
    interval: 20000
    repeat: false
    onTriggered: {
      if (!pollProcess.running) return
      pollProcess.running = false
      root.everPolled = true
      root.lastError = "openlogi list timed out"
      root.stale = root.hasDevices
    }
  }

  Process {
    id: pollProcess
    running: false
    command: []
    stdout: StdioCollector { id: pollStdout; waitForEnd: true }
    stderr: StdioCollector { id: pollStderr; waitForEnd: true }
    onExited: function(exitCode) {
      watchdog.stop()
      root.applyResult(exitCode, pollStdout.text, pollStderr.text)
    }
  }
}
