.pragma library

// Pure helpers for the OpenLogi battery widget: parse `openlogi list`
// output, classify the agent state, pick glyphs. No QML or process access
// here so the whole file runs under node for tests (see test/model.test.js).
//
// Output format reference: crates/openlogi-cli/src/cmd/list.rs at v0.8.3.
// Header lines about provenance go to stderr; stdout holds the device tree.

// "  ├─ slot 3 ● MX MCHNCL M (keyboard, wpid=b367, battery=95% full (discharging))"
// "  └─ slot 1 ○ MX Master 3S (mouse, wpid=4082, battery=—)"
var DEVICE_RE = /^\s*[├└]─\s+slot\s+(\d+)\s+([●○])\s+(.+?)\s+\((\w+),\s+wpid=(\S+?),\s+(?:battery=(\d+)%\s+(\w+)\s+\(([^)]*)\)|battery=—)\)\s*$/
// "Logi Bolt Receiver (0123456789ABCDEF, vid=046d pid=c548)"
var RECEIVER_RE = /^(\S.*?)\s+\(([^,()]+),\s+vid=([0-9a-fA-F]{4})\s+pid=([0-9a-fA-F]{4})\)\s*$/
// "  │       model_ids=[b367,0000,0000] ext=00 serial=2201ABC0DEF1 unit_id=00aa11bb transports=btle"
var MODEL_RE = /^\s*(?:│\s*)?model_ids=\[([^\]]*)\]\s+ext=(\S+)\s+serial=(\S+)\s+unit_id=(\S+)\s+transports=(\S+)/
var NO_PAIRED_RE = /└─\s+no paired devices/
var NOTHING_RE = /^No Logitech HID\+\+ devices or webcams found\./m
var CAMERAS_RE = /^Cameras \(\d+ Logitech UVC\)/m

function isCharging(status) {
  var s = String(status || "").toLowerCase()
  return s.indexOf("charg") !== -1 && s.indexOf("dis") !== 0
}

// Parse stdout of `openlogi list`. Returns:
//   devices      [{slot, online, name, kind, wpid, battery, level, status, charging, serial, transports, receiver}]
//   receivers    [{name, uid, vid, pid}]
//   noPaired     a receiver printed "no paired devices"
//   nothingFound the exit-2 "No Logitech HID++ devices or webcams found." text
//   hasCameras   a "Cameras (N Logitech UVC)" block is present
//   parseMiss    stdout had content but nothing we understand — format changed?
function parseDeviceList(stdout) {
  var text = String(stdout || "")
  var lines = text.split("\n")
  var devices = []
  var receivers = []
  var receiver = ""
  var noPaired = false
  var inCameras = false

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.trim() === "") continue

    if (CAMERAS_RE.test(line)) { inCameras = true; continue }
    if (inCameras && /^\s/.test(line)) continue
    inCameras = false

    var m = DEVICE_RE.exec(line)
    if (m) {
      var hasBattery = m[6] !== undefined
      var status = hasBattery ? String(m[8] || "").toLowerCase() : ""
      devices.push({
        slot: parseInt(m[1], 10),
        online: m[2] === "●",
        name: m[3],
        kind: String(m[4]).toLowerCase(),
        wpid: m[5],
        battery: hasBattery ? parseInt(m[6], 10) : null,
        level: hasBattery ? String(m[7]).toLowerCase() : "",
        status: status,
        charging: hasBattery && isCharging(status),
        serial: "",
        transports: "",
        receiver: receiver
      })
      continue
    }

    m = MODEL_RE.exec(line)
    if (m) {
      if (devices.length > 0) {
        var last = devices[devices.length - 1]
        last.serial = m[3] === "—" ? "" : m[3]
        last.transports = m[5] === "—" ? "" : m[5]
      }
      continue
    }

    if (NO_PAIRED_RE.test(line)) { noPaired = true; continue }

    m = RECEIVER_RE.exec(line)
    if (m && !/^\s/.test(line)) {
      receiver = m[1]
      receivers.push({ name: m[1], uid: m[2] === "—" ? "" : m[2], vid: m[3].toLowerCase(), pid: m[4].toLowerCase() })
      continue
    }
  }

  var nothingFound = NOTHING_RE.test(text)
  var hasCameras = CAMERAS_RE.test(text)
  var parseMiss = text.trim() !== ""
    && devices.length === 0
    && !noPaired
    && !nothingFound
    && !(hasCameras && receivers.length === 0)

  return {
    devices: devices,
    receivers: receivers,
    noPaired: noPaired,
    nothingFound: nothingFound,
    hasCameras: hasCameras,
    parseMiss: parseMiss
  }
}

// "agent" when the CLI read the running agent's inventory, "direct" when it
// fell back to enumerating hardware itself, "unknown" when neither line is
// present (older/newer CLI, or the wrapper failed before running it).
function agentStateFromStderr(stderr) {
  var s = String(stderr || "")
  if (/no agent reachable|reading hardware directly/i.test(s)) return "direct"
  if (/inventory read from the running agent/i.test(s)) return "agent"
  return "unknown"
}

// Devices that count for the bar icon: online and reporting a percentage.
function reportingDevices(devices) {
  var out = []
  var list = Array.isArray(devices) ? devices : []
  for (var i = 0; i < list.length; i++) {
    var d = list[i]
    if (d && d.online && typeof d.battery === "number" && isFinite(d.battery)) out.push(d)
  }
  return out
}

// The device with the lowest battery among reporting devices, or null.
function lowestDevice(devices) {
  var list = reportingDevices(devices)
  var best = null
  for (var i = 0; i < list.length; i++) {
    if (best === null || list[i].battery < best.battery) best = list[i]
  }
  return best
}

function lowestBattery(devices) {
  var d = lowestDevice(devices)
  return d ? d.battery : -1
}

function anyLow(devices, threshold) {
  var list = reportingDevices(devices)
  for (var i = 0; i < list.length; i++) {
    if (list[i].battery <= threshold && !list[i].charging) return true
  }
  return false
}

// Same ten-step glyph sets omarchy.power uses, so the bar reads as one family.
var CHARGING_ICONS = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
var DEFAULT_ICONS = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
var ICON_ALERT = "󰂃"
var ICON_UNKNOWN = "󰂑"

function batteryIcon(percent, charging) {
  var p = Number(percent)
  if (!isFinite(p) || p < 0) return ICON_UNKNOWN
  var index = Math.max(0, Math.min(9, Math.floor(p / 10)))
  return charging ? CHARGING_ICONS[index] : DEFAULT_ICONS[index]
}

function kindIcon(kind) {
  var k = String(kind || "").toLowerCase()
  if (k === "mouse" || k === "trackball") return "󰍽"
  if (k === "keyboard" || k === "numpad") return "󰌌"
  if (k === "touchpad" || k === "trackpad") return "󰟸"
  if (k === "headset") return "󰋋"
  if (k === "presenter" || k === "remote") return "󰑔"
  return "󰕓"
}

function capitalize(s) {
  var t = String(s || "")
  return t === "" ? "" : t.charAt(0).toUpperCase() + t.slice(1)
}

// Caption under a device row: "Charging", "Charging slowly", "Offline",
// "Low", or the kind when there's nothing more interesting to say.
function statusText(device) {
  if (!device) return ""
  if (!device.online) return "Offline"
  if (device.battery === null || device.battery === undefined) return capitalize(device.kind) + " · no battery reported"
  if (device.status === "chargingslow") return "Charging slowly"
  if (device.charging) return "Charging"
  if (device.status === "full" || device.level === "full") return capitalize(device.kind) + " · full"
  if (device.level === "critical") return "Critical"
  if (device.level === "low") return "Low"
  return capitalize(device.kind)
}

function percentText(device) {
  if (!device || !device.online) return "—"
  if (device.battery === null || device.battery === undefined) return "—"
  return device.battery + "%"
}

// One-line summary for the hero / tooltip.
function summaryText(devices) {
  var list = Array.isArray(devices) ? devices : []
  if (list.length === 0) return "No devices"
  var parts = []
  for (var i = 0; i < list.length; i++) {
    var d = list[i]
    parts.push(d.name + " " + percentText(d))
  }
  return parts.join(" · ")
}

function toInt(value, fallback) {
  var n = parseInt(value, 10)
  return isFinite(n) ? n : fallback
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

if (typeof module !== "undefined") {
  module.exports = {
    parseDeviceList: parseDeviceList,
    agentStateFromStderr: agentStateFromStderr,
    reportingDevices: reportingDevices,
    lowestDevice: lowestDevice,
    lowestBattery: lowestBattery,
    anyLow: anyLow,
    batteryIcon: batteryIcon,
    kindIcon: kindIcon,
    statusText: statusText,
    percentText: percentText,
    summaryText: summaryText,
    toInt: toInt,
    clamp: clamp,
    ICON_ALERT: ICON_ALERT,
    ICON_UNKNOWN: ICON_UNKNOWN
  }
}
