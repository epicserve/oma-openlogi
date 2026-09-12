// Run with: node --test test/
// Model.js starts with `.pragma library` (a QML directive); strip it before
// evaluating the file as CommonJS.
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")
const test = require("node:test")
const assert = require("node:assert/strict")

function loadModel() {
  const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
  const module = { exports: {} }
  vm.runInNewContext(src, { module, exports: module.exports })
  return module.exports
}

function fixture(name) {
  return fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8")
}

const Model = loadModel()

test("parses the live two-device Bolt listing", () => {
  const r = Model.parseDeviceList(fixture("two-devices.stdout"))
  assert.equal(r.parseMiss, false)
  assert.equal(r.nothingFound, false)
  assert.equal(r.noPaired, false)
  assert.equal(r.receivers.length, 1)
  assert.equal(r.receivers[0].name, "Logi Bolt Receiver")
  assert.equal(r.receivers[0].uid, "0123456789ABCDEF")
  assert.equal(r.devices.length, 2)

  const kb = r.devices[0]
  assert.deepEqual(
    { slot: kb.slot, online: kb.online, name: kb.name, kind: kb.kind, wpid: kb.wpid, battery: kb.battery, level: kb.level, status: kb.status, charging: kb.charging, serial: kb.serial, transports: kb.transports, receiver: kb.receiver },
    { slot: 3, online: true, name: "MX MCHNCL M", kind: "keyboard", wpid: "b367", battery: 95, level: "full", status: "discharging", charging: false, serial: "2201ABC0DEF1", transports: "btle", receiver: "Logi Bolt Receiver" }
  )
  const mouse = r.devices[1]
  assert.equal(mouse.name, "MX Master 4")
  assert.equal(mouse.battery, 85)
  assert.equal(mouse.serial, "2502XYZ0GHI2")
})

test("handles offline, unknown, no-battery and slow-charging devices", () => {
  const r = Model.parseDeviceList(fixture("mixed.stdout"))
  assert.equal(r.parseMiss, false)
  assert.equal(r.devices.length, 4)

  const [offline, unknown, slow, noSerial] = r.devices
  assert.equal(offline.online, false)
  assert.equal(offline.battery, null)
  assert.equal(offline.name, "MX Master 3S")

  assert.equal(unknown.name, "Unknown device")
  assert.equal(unknown.wpid, "?")
  assert.equal(unknown.battery, null)

  assert.equal(slow.battery, 10)
  assert.equal(slow.level, "critical")
  assert.equal(slow.status, "chargingslow")
  assert.equal(slow.charging, true)

  assert.equal(noSerial.serial, "")
  assert.equal(noSerial.transports, "")
})

test("a receiver with nothing paired is not a parse miss", () => {
  const r = Model.parseDeviceList(fixture("no-paired.stdout"))
  assert.equal(r.devices.length, 0)
  assert.equal(r.noPaired, true)
  assert.equal(r.parseMiss, false)
  assert.equal(r.receivers.length, 1)
})

test("the exit-2 nothing-found text is not a parse miss", () => {
  const r = Model.parseDeviceList(fixture("nothing-found.stdout"))
  assert.equal(r.devices.length, 0)
  assert.equal(r.nothingFound, true)
  assert.equal(r.parseMiss, false)
})

test("a cameras-only listing is not a parse miss, camera lines are not devices", () => {
  const r = Model.parseDeviceList(fixture("cameras-only.stdout"))
  assert.equal(r.devices.length, 0)
  assert.equal(r.hasCameras, true)
  assert.equal(r.parseMiss, false)
})

test("devices plus a cameras block parse only the devices", () => {
  const r = Model.parseDeviceList(fixture("devices-and-camera.stdout"))
  assert.equal(r.devices.length, 2)
  assert.equal(r.hasCameras, true)
  assert.equal(r.parseMiss, false)
})

test("two receivers keep devices attributed to their receiver", () => {
  const r = Model.parseDeviceList(fixture("two-receivers.stdout"))
  assert.equal(r.receivers.length, 2)
  assert.equal(r.devices.length, 3)
  assert.equal(r.devices[0].receiver, "Logi Bolt Receiver")
  assert.equal(r.devices[2].receiver, "Unifying Receiver")
})

test("unrecognised output is flagged as a parse miss", () => {
  const r = Model.parseDeviceList("Receiver: Bolt\n  - MX Master 4: 85%\n")
  assert.equal(r.devices.length, 0)
  assert.equal(r.parseMiss, true)
  assert.equal(Model.parseDeviceList("").parseMiss, false)
  assert.equal(Model.parseDeviceList("   \n").parseMiss, false)
})

test("agent state comes from stderr", () => {
  assert.equal(Model.agentStateFromStderr("(inventory read from the running agent)\n"), "agent")
  assert.equal(Model.agentStateFromStderr("(no agent reachable — reading hardware directly; macOS judges this process's Input Monitoring grant, not the agent's)\n"), "direct")
  assert.equal(Model.agentStateFromStderr("note: the agent speaks protocol v3, this CLI expects v4 — reading hardware directly\n"), "direct")
  assert.equal(Model.agentStateFromStderr(""), "unknown")
})

test("lowest battery ignores offline and battery-less devices", () => {
  const devices = Model.parseDeviceList(fixture("mixed.stdout")).devices
  // offline MX Master 3S (no battery), Unknown (no battery), slow-charging at 10%, keyboard at 60%
  assert.equal(Model.lowestBattery(devices), 10)
  assert.equal(Model.lowestDevice(devices).status, "chargingslow")
  assert.equal(Model.lowestBattery([]), -1)
  const live = Model.parseDeviceList(fixture("two-devices.stdout")).devices
  assert.equal(Model.lowestBattery(live), 85)
})

test("anyLow respects threshold and skips charging devices", () => {
  const devices = Model.parseDeviceList(fixture("mixed.stdout")).devices
  assert.equal(Model.anyLow(devices, 20), false) // the 10% device is charging
  const live = Model.parseDeviceList(fixture("two-devices.stdout")).devices
  assert.equal(Model.anyLow(live, 20), false)
  assert.equal(Model.anyLow(live, 85), true)
})

test("battery glyphs follow the ten-step scale", () => {
  assert.equal(Model.batteryIcon(0, false), "󰁺")
  assert.equal(Model.batteryIcon(85, false), "󰂂")
  assert.equal(Model.batteryIcon(100, false), "󰁹")
  assert.equal(Model.batteryIcon(100, true), "󰂅")
  assert.equal(Model.batteryIcon(-1, false), Model.ICON_UNKNOWN)
  assert.equal(Model.batteryIcon("nope", false), Model.ICON_UNKNOWN)
})

test("row text", () => {
  const devices = Model.parseDeviceList(fixture("mixed.stdout")).devices
  assert.equal(Model.statusText(devices[0]), "Offline")
  assert.equal(Model.percentText(devices[0]), "—")
  assert.equal(Model.statusText(devices[1]), "Mouse · no battery reported")
  assert.equal(Model.statusText(devices[2]), "Charging slowly")
  assert.equal(Model.percentText(devices[2]), "10%")
  assert.equal(Model.statusText(devices[3]), "Keyboard")
  const live = Model.parseDeviceList(fixture("two-devices.stdout")).devices
  assert.equal(Model.statusText(live[0]), "Keyboard · full")
  assert.equal(Model.summaryText(live), "MX MCHNCL M 95% · MX Master 4 85%")
  assert.equal(Model.summaryText([]), "No devices")
})
