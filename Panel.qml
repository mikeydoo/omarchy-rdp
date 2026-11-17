import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Remote Session bar widget: the icon shows the state at a glance; the panel sets the
// remote session up, shows who's connected and how to connect, lists the checks with
// fixes, and has the controls. The same widget runs in both sessions and shows the
// controls that make sense where it is.
Panel {
  id: root
  moduleName: "hypr-rdp"
  ipcTarget: "hypr-rdp"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var st: svc.status
  readonly property string state: svc.state
  readonly property bool inRemote: svc.inRemote
  // nf-md-remote_desktop
  readonly property string glyph: "󰢹"
  readonly property color barIconColor: state === "attention" ? urgent
    : (state === "connected" || state === "ready") ? barForeground
    : Qt.darker(barForeground, 1.55)

  readonly property string connectCommand: st
    ? "xfreerdp3 /v:" + (st.address || "<host>") + " /u:" + (st.user || "$USER")
      + " /sec:tls /cert:ignore /dynamic-resolution"
    : ""

  // Two-step buttons for anything that closes windows: the first click arms, the
  // second (within a few seconds) does it.
  property string armed: ""
  function confirmThen(name, action) {
    if (armed === name) { armed = ""; action() }
    else { armed = name; disarm.restart() }
  }
  Timer { id: disarm; interval: 4000; onTriggered: root.armed = "" }

  property bool copied: false
  Timer { id: copiedReset; interval: 1500; onTriggered: root.copied = false }

  function stateText() {
    if (!svc.loaded) return strings.t("state.loading")
    return strings.t("state." + state)
  }

  function detailText() {
    if (!st) return ""
    if (inRemote) return strings.t("detail.remote")
    if (state === "not-set-up") return strings.t("detail.notSetUp")
    if (st.client) return strings.t("detail.connected").arg(st.client)
    if (!st.rdpActive) return strings.t("detail.off")
    return strings.t("detail.ready").arg(st.address || "")
  }

  function remoteText() {
    if (!st) return ""
    if (st.restartPending) return strings.t("remote.restartPending")
    if (!st.remoteActive) return strings.t("remote.stopped")
    return st.remoteLocked === true ? strings.t("remote.locked") : strings.t("remote.running")
  }

  Service {
    id: svc
    panelOpen: root.opened
    lockOnFirstStart: root.setting("lockOnFirstStart", false) === true
    autoRebuild: root.setting("autoRebuild", true) !== false
    onRebuilt: function(ok) {
      Quickshell.execDetached(["notify-send", "-a", strings.t("title"),
        strings.t(ok ? "notify.rebuilt.title" : "notify.rebuildFailed.title"),
        strings.t(ok ? "notify.rebuilt.body" : "notify.rebuildFailed.body")])
    }
  }
  property alias service: svc

  // omarchy-shell hypr-rdp toggle — handy for a keybinding.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { svc.refresh(); return "ok" }
  }

  onOpenedChanged: if (opened) {
    armed = ""
    svc.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        OpticalGlyph {
          anchors.fill: parent
          text: root.glyph
          fontFamily: root.fontFamily
          fontSize: button.iconSize
          color: root.barIconColor
        }
      }
    }
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t.toLowerCase() === "r") svc.refresh() }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.spacing.lg

          // --- hero: state, detail, RDP switch ---------------------------------------
          PanelHero {
            width: parent.width
            title: strings.t("title")
            meta: root.stateText()
            detail: root.detailText()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              OpticalGlyph {
                text: root.glyph
                fontFamily: root.fontFamily
                fontSize: Style.font.display
                color: root.state === "attention" ? root.urgent : root.foreground
              }
            }
            trailingControl: (root.st && root.st.setup && !root.inRemote) ? rdpSwitch : null
          }

          Component {
            id: rdpSwitch
            ToggleSwitch {
              checked: !!(root.st && root.st.rdpEnabled)
              busy: svc.busy === "rdp"
              foreground: root.foreground
              onToggled: svc.run("rdp", ["rdp", checked ? "off" : "on"])
            }
          }

          Button {
            visible: !!root.st && !root.st.setup && !root.inRemote
            width: parent.width
            text: strings.t("setUp")
            iconText: ""
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: svc.runInTerminal(["install"])
          }

          // --- connect -----------------------------------------------------------------
          Column {
            visible: !!root.st && root.st.setup && !root.inRemote
            width: parent.width
            spacing: Style.spacing.sm

            PanelSectionHeader {
              text: strings.t("section.connect")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            PlainText {
              width: parent.width
              text: strings.t("connect.hint")
              color: root.dim
            }
            RowLayout {
              width: parent.width
              spacing: Style.spacing.md
              PlainText {
                Layout.fillWidth: true
                text: root.connectCommand
                wrapMode: Text.WrapAnywhere
                font.pixelSize: Style.font.caption
              }
              Button {
                text: root.copied ? strings.t("copied") : strings.t("copy")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  Quickshell.execDetached(["wl-copy", "--", root.connectCommand])
                  root.copied = true
                  copiedReset.restart()
                }
              }
            }
          }

          // --- remote session ------------------------------------------------------------
          Column {
            visible: !!root.st && root.st.setup
            width: parent.width
            spacing: Style.spacing.sm

            PanelSectionHeader {
              text: strings.t("section.session")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            PlainText {
              width: parent.width
              visible: !root.inRemote
              text: root.remoteText()
              color: root.st && root.st.restartPending ? root.urgent : root.foreground
            }
            Flow {
              width: parent.width
              spacing: Style.spacing.md

              Button {
                visible: !root.inRemote && !!root.st && !!root.st.client
                text: strings.t("disconnect")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.run("kick", ["kick"])
              }
              Button {
                visible: !root.inRemote && !!root.st && root.st.remoteActive
                text: root.armed === "restart" ? strings.t("confirm") : strings.t("restart")
                foreground: root.armed === "restart" ? root.urgent : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.confirmThen("restart", function() { svc.run("restart-remote", ["restart-remote"]) })
              }
              Button {
                visible: !root.inRemote && !!root.st && root.st.remoteActive
                text: root.armed === "logout" ? strings.t("confirm") : strings.t("logout")
                foreground: root.armed === "logout" ? root.urgent : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.confirmThen("logout", function() { svc.run("logout-remote", ["logout-remote"]) })
              }
              Button {
                visible: root.inRemote
                text: root.armed === "logout-desk" ? strings.t("confirm") : strings.t("logoutDesk")
                foreground: root.armed === "logout-desk" ? root.urgent : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.confirmThen("logout-desk", function() { svc.run("logout-desk", ["logout-desk"]) })
              }
            }
          }

          // --- checks ------------------------------------------------------------------------
          Column {
            visible: !!root.st && !root.inRemote
            width: parent.width
            spacing: Style.spacing.sm

            PanelSectionHeader {
              text: strings.t("section.checks")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            PlainText {
              visible: svc.problems.length === 0
              width: parent.width
              text: "  " + strings.t("checks.allGood")
              color: root.dim
            }
            Repeater {
              model: svc.problems
              RowLayout {
                id: checkRow
                required property var modelData
                width: column.width
                spacing: Style.spacing.md
                PlainText {
                  Layout.fillWidth: true
                  text: (checkRow.modelData.severity === "error" ? "  " : "  ") + String(checkRow.modelData.text || "")
                  color: checkRow.modelData.severity === "error" ? root.urgent : root.foreground
                  wrapMode: Text.WordWrap
                }
                Button {
                  visible: !!checkRow.modelData.fix && !(checkRow.modelData.fix === "install" && root.st && !root.st.setup)
                  text: svc.busy !== "" && svc.busy === String(checkRow.modelData.fix).replace("-on", "")
                    ? strings.t("working") : strings.t("fix")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: svc.fix(checkRow.modelData)
                }
              }
            }
            PlainText {
              visible: svc.lastError !== ""
              width: parent.width
              text: svc.lastError
              color: root.urgent
              wrapMode: Text.WordWrap
            }
          }

          // --- plugin: update / repair / uninstall --------------------------------------------
          Column {
            visible: !!root.st && root.st.setup && !root.inRemote
            width: parent.width
            spacing: Style.spacing.sm

            PanelSeparator { width: parent.width; foreground: root.foreground }
            Flow {
              width: parent.width
              spacing: Style.spacing.md
              Button {
                visible: !!root.st && root.st.isGitCheckout
                text: strings.t("update")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.runInTerminal(["update"])
              }
              Button {
                text: strings.t("repair")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.runInTerminal(["install"])
              }
              Button {
                text: root.armed === "uninstall" ? strings.t("confirm") : strings.t("uninstall")
                foreground: root.armed === "uninstall" ? root.urgent : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.confirmThen("uninstall", function() { svc.runInTerminal(["uninstall", "--yes"]) })
              }
            }
            PlainText {
              width: parent.width
              text: root.st ? ("v" + (root.st.version || "?") + "  ·  hypr-rdp " + (root.st.hyprRdp || "-")
                + "  ·  aquamarine " + (root.st.aquamarine || "-")) : ""
              color: root.dim
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // Plain text only: status text comes from commands and files (Omarchy plugin rule).
  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }
}
