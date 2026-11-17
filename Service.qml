import QtQuick
import Quickshell
import Quickshell.Io

// State and actions for the Omarchy RDP panel. Everything goes through
// bin/omarchy-rdp-ctl; this only polls its status and runs its commands.
Item {
  id: root

  // Third-party plugins have no OMARCHY_PATH-style root; resolve our own directory.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string ctl: pluginDir + "/bin/omarchy-rdp-ctl"
  // The remote session's Hyprland carries the render-node variable the launcher sets.
  readonly property bool inRemote: !!Quickshell.env("AQ_HEADLESS_RENDER_NODE")

  // Set by the panel.
  property bool panelOpen: false
  property bool lockOnFirstStart: false
  property bool autoRebuild: true

  property var status: null
  readonly property bool loaded: status !== null
  readonly property string state: status ? String(status.state || "") : "loading"
  readonly property var problems: status && Array.isArray(status.checks)
    ? status.checks.filter(function(c) { return !c.ok }) : []

  // What's running, so its button can say so; "" when nothing.
  property string busy: ""
  property string lastError: ""
  property bool _refreshAgain: false
  property string _autoRebuildTried: ""
  property bool _lockedOnce: false

  signal rebuilt(bool ok)

  function refresh() {
    if (statusProcess.running) { _refreshAgain = true; return }
    statusProcess.running = true
  }

  function applyStatus(text) {
    var parsed = null
    try { parsed = JSON.parse(text) } catch (e) { return }
    if (!parsed || typeof parsed !== "object") return
    status = parsed
    maybeAutoRebuild()
  }

  // A quick action (no terminal): run it, then read the status again.
  function run(name, args) {
    if (actionProcess.running) return
    busy = name
    lastError = ""
    actionProcess.command = [ctl].concat(args)
    actionProcess.running = true
  }

  // Set up / repair / update / uninstall need a terminal: the AUR build and sudo
  // prompts happen there, as with Omarchy's own installers.
  function runInTerminal(args) {
    var quoted = [ctl].concat(args).map(function(a) { return "'" + String(a).replace(/'/g, "'\\''") + "'" })
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", quoted.join(" ")])
    refreshSoon.restart()
  }

  function fix(check) {
    if (!check || !check.fix) return
    if (check.fix === "install") runInTerminal(["install"])
    else if (check.fix === "rebuild") run("rebuild", ["rebuild"])
    else if (check.fix === "rdp-on") run("rdp", ["rdp", "on"])
    else if (check.fix === "restart-remote") run("restart-remote", ["restart-remote"])
  }

  // Desk only: rebuild the patched libaquamarine as soon as an update changes aquamarine,
  // once per aquamarine version, instead of at the remote session's next start.
  function maybeAutoRebuild() {
    if (inRemote || !autoRebuild || !status || !status.setup) return
    var aq = String(status.aquamarine || "")
    if (aq === "" || status.patched === aq || status.rebuildFailed === aq) return
    if (_autoRebuildTried === aq || actionProcess.running) return
    _autoRebuildTried = aq
    run("rebuild", ["rebuild"])
  }

  // Optional (setting, off by default): lock this remote session once per start of it.
  // omarchy-rdp-ctl keeps the once-per-start marker, so a shell restart doesn't lock again.
  function maybeLock() {
    if (!inRemote || !lockOnFirstStart || _lockedOnce) return
    _lockedOnce = true
    Quickshell.execDetached([ctl, "lock-once"])
  }
  onLockOnFirstStartChanged: maybeLock()

  Component.onCompleted: {
    refresh()
    maybeLock()
  }

  // Quick while the panel is open; slow otherwise (the bar icon shows the state).
  Timer {
    interval: root.panelOpen ? 2000 : 15000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  // After a terminal action, look again a few times while it runs.
  Timer {
    id: refreshSoon
    interval: 3000
    repeat: true
    property int left: 0
    onRunningChanged: if (running) left = 20
    onTriggered: {
      root.refresh()
      if (--left <= 0) stop()
    }
  }

  Process {
    id: statusProcess
    command: [root.ctl, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onExited: function() {
      if (root._refreshAgain) {
        root._refreshAgain = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: actionProcess
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var name = root.busy
      root.busy = ""
      if (exitCode !== 0) root.lastError = String(actionErr.text || "").trim().split("\n").pop()
      if (name === "rebuild") root.rebuilt(exitCode === 0)
      root.refresh()
    }
  }
}
