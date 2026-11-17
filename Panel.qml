import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Omarchy RDP bar widget: the icon shows the state at a glance; the panel sets the
// remote session up, shows who's connected and how to connect, lists what needs fixing,
// and has the controls. The same widget runs in both sessions and shows the controls
// that make sense where it is. Laid out like Omarchy's own panels (Tailscale, Dropbox):
// a hero with the on/off switch, then sections of rows.
Panel {
  id: root
  moduleName: "omarchy-rdp"
  ipcTarget: "omarchy-rdp"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var st: svc.status
  readonly property string state: svc.state
  readonly property bool inRemote: svc.inRemote
  readonly property bool isSetUp: !!st && st.setup === true
  readonly property bool active: state === "ready" || state === "connected"

  // nf-md-remote_desktop
  readonly property string glyph: "󰢹"
  readonly property color barIconColor: state === "attention" ? urgent
    : active || inRemote ? barForeground
    : Qt.darker(barForeground, 1.55)

  readonly property string connectCommand: st
    ? "xfreerdp3 /v:" + (st.address || "<host>") + " /u:" + (st.user || "$USER")
      + " /sec:tls /cert:ignore /dynamic-resolution"
    : ""

  // Problems worth showing. Before setup only the ones setup can't fix (no GPU render
  // node, an Omarchy change): the rest is simply "not installed yet".
  readonly property var shownProblems: svc.problems.filter(function(c) {
    return root.isSetUp || !c.fix
  })

  // Two-step rows for anything that closes windows: the first click arms, the second
  // (within a few seconds) does it.
  property string armed: ""
  function confirmThen(name, action) {
    if (armed === name) { armed = ""; action() }
    else { armed = name; disarm.restart() }
  }
  Timer { id: disarm; interval: 4000; onTriggered: root.armed = "" }

  property bool copied: false
  Timer { id: copiedReset; interval: 1500; onTriggered: root.copied = false }

  function metaText() {
    if (!svc.loaded) return strings.t("state.loading")
    if (inRemote) return strings.t("meta.remote")
    if (state === "connected") return strings.t("meta.connected")
    if (state === "ready") return strings.t("meta.ready").arg(st.address || "")
    return strings.t("state." + state)
  }

  // The short pill beside the title: who's connected.
  function heroTag() {
    if (!st || inRemote) return ""
    return st.client ? String(st.client) : ""
  }

  function remoteCaption() {
    if (!st) return ""
    if (st.restartPending) return strings.t("remote.restartPending")
    if (!st.remoteActive) return strings.t("remote.stopped")
    return st.remoteLocked === true ? strings.t("remote.locked") : strings.t("remote.running")
  }

  function copyCommand() {
    Quickshell.execDetached(["wl-copy", "--", root.connectCommand])
    root.copied = true
    copiedReset.restart()
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

  // omarchy-shell omarchy-rdp toggle — handy for a keybinding.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { svc.refresh(); return "ok" }
  }

  onOpenedChanged: if (opened) {
    armed = ""
    panelFlick.contentY = 0
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = t.toLowerCase()
        if (key === "r") svc.refresh()
        else if (key === "c" && root.isSetUp && !root.inRemote) root.copyCommand()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // --- hero: state and the RDP switch ------------------------------------------
          PanelHero {
            id: hero
            width: parent.width
            title: strings.t("title")
            meta: root.metaText()
            detail: root.heroTag()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.active || root.inRemote ? 1.0 : 0.5
            iconComponent: Component {
              OpticalGlyph {
                width: Style.font.display
                height: Style.font.display
                text: root.glyph
                fontFamily: root.fontFamily
                fontSize: Style.font.display
                color: root.state === "attention" ? root.urgent : root.foreground
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: rdpSwitch
                visible: root.isSetUp && !root.inRemote
                checked: !!(root.st && root.st.rdpEnabled)
                busy: svc.busy === "rdp"
                foreground: root.foreground
                onToggled: svc.run("rdp", ["rdp", checked ? "off" : "on"])

                PanelToolTip {
                  visible: rdpSwitch.containsMouse
                  text: strings.t(rdpSwitch.checked ? "rdp.turnOff" : "rdp.turnOn")
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          // Last action's error, as Omarchy's panels show it under the hero.
          Text {
            textFormat: Text.PlainText
            visible: svc.lastError !== ""
            width: parent.width
            text: svc.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // --- not set up: what it is, and Set up -----------------------------------------
          Column {
            visible: !!root.st && !root.isSetUp && !root.inRemote
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("intro")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            ActionRow {
              glyph: ""
              label: strings.t("setUp")
              caption: strings.t("setUp.caption")
              bordered: true
              chevron: true
              onActivated: svc.runInTerminal(["install"])
            }
          }

          // --- needs attention ------------------------------------------------------------
          PanelSeparator {
            visible: root.shownProblems.length > 0 && !root.inRemote
            foreground: root.foreground
          }

          Column {
            visible: root.shownProblems.length > 0 && !root.inRemote
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: strings.t("section.attention")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.shownProblems
              ActionRow {
                id: problemRow
                required property var modelData
                readonly property bool working: svc.busy !== ""
                  && svc.busy === String(problemRow.modelData.fix || "").replace("-on", "")
                glyph: ""
                glyphColor: problemRow.modelData.severity === "error" ? root.urgent : root.foreground
                label: String(problemRow.modelData.text || "")
                hint: !problemRow.modelData.fix ? "" : problemRow.working ? strings.t("working") : strings.t("fix")
                interactive: !!problemRow.modelData.fix
                onActivated: svc.fix(problemRow.modelData)
              }
            }
          }

          // --- connect -------------------------------------------------------------------
          PanelSeparator {
            visible: root.isSetUp && !root.inRemote
            foreground: root.foreground
          }

          Column {
            visible: root.isSetUp && !root.inRemote
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: strings.t("section.connect")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ActionRow {
              glyph: ""
              label: root.copied ? strings.t("copied") : strings.t("copyCommand")
              caption: root.connectCommand
              hint: "C"
              onActivated: root.copyCommand()
            }
          }

          // --- the remote session ------------------------------------------------------------
          PanelSeparator {
            visible: root.isSetUp
            foreground: root.foreground
          }

          Column {
            visible: root.isSetUp
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: root.inRemote ? strings.t("section.desk") : strings.t("section.session")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ActionRow {
              visible: !root.inRemote
              glyph: root.st && root.st.remoteActive ? "" : ""
              label: root.st && root.st.remoteActive ? strings.t("remote.title.running") : strings.t("remote.title.stopped")
              caption: root.remoteCaption()
              captionColor: root.st && root.st.restartPending ? root.urgent : root.dim
              interactive: false
            }

            ActionRow {
              visible: !root.inRemote && !!root.st && !!root.st.client
              glyph: ""
              label: strings.t("disconnect")
              caption: root.st ? strings.t("disconnect.caption").arg(root.st.client || "") : ""
              hint: svc.busy === "kick" ? strings.t("working") : ""
              onActivated: svc.run("kick", ["kick"])
            }

            ActionRow {
              visible: !root.inRemote && !!root.st && root.st.remoteActive
              glyph: ""
              label: root.armed === "restart" ? strings.t("confirm") : strings.t("restart")
              labelColor: root.armed === "restart" ? root.urgent : root.foreground
              caption: strings.t("restart.caption")
              hint: svc.busy === "restart-remote" ? strings.t("working") : ""
              onActivated: root.confirmThen("restart", function() { svc.run("restart-remote", ["restart-remote"]) })
            }

            ActionRow {
              visible: !root.inRemote && !!root.st && root.st.remoteActive
              glyph: ""
              label: root.armed === "logout" ? strings.t("confirm") : strings.t("logout")
              labelColor: root.armed === "logout" ? root.urgent : root.foreground
              caption: strings.t("logout.caption")
              hint: svc.busy === "logout-remote" ? strings.t("working") : ""
              onActivated: root.confirmThen("logout", function() { svc.run("logout-remote", ["logout-remote"]) })
            }

            ActionRow {
              visible: root.inRemote
              glyph: ""
              label: root.armed === "logout-desk" ? strings.t("confirm") : strings.t("logoutDesk")
              labelColor: root.armed === "logout-desk" ? root.urgent : root.foreground
              caption: strings.t("logoutDesk.caption")
              hint: svc.busy === "logout-desk" ? strings.t("working") : ""
              onActivated: root.confirmThen("logout-desk", function() { svc.run("logout-desk", ["logout-desk"]) })
            }
          }

          // --- footer: update / repair / uninstall, versions ------------------------------------
          PanelSeparator {
            visible: root.isSetUp && !root.inRemote
            foreground: root.foreground
          }

          Column {
            visible: root.isSetUp && !root.inRemote
            width: parent.width
            spacing: Style.space(8)

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Button {
                visible: !!root.st && root.st.isGitCheckout
                Layout.fillWidth: true
                text: strings.t("update")
                iconText: ""
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.runInTerminal(["update"])
              }
              Button {
                Layout.fillWidth: true
                text: strings.t("repair")
                iconText: ""
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: svc.runInTerminal(["install"])
              }
              Button {
                Layout.fillWidth: true
                text: root.armed === "uninstall" ? strings.t("confirmShort") : strings.t("uninstall")
                iconText: ""
                bordered: true
                foreground: root.armed === "uninstall" ? root.urgent : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.confirmThen("uninstall", function() { svc.runInTerminal(["uninstall", "--yes"]) })
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.st ? ("v" + (root.st.version || "?") + "  ·  hypr-rdp " + (root.st.hyprRdp || "–")
                + "  ·  aquamarine " + (root.st.aquamarine || "–")) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  // A row in the panel: icon, label, optional caption below and hint on the right.
  // Clickable unless `interactive` is false; highlights under the pointer.
  component ActionRow: CursorSurface {
    id: actionRow
    property string glyph: ""
    property color glyphColor: root.foreground
    property string label: ""
    property color labelColor: root.foreground
    property string caption: ""
    property color captionColor: root.dim
    property string hint: ""
    property bool chevron: false
    property bool wrap: true
    property bool interactive: true
    signal activated()

    width: parent ? parent.width : implicitWidth
    foreground: root.foreground
    hasCursor: interactive && rowMouse.containsMouse
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: actionRow.interactive
      enabled: actionRow.interactive
      cursorShape: actionRow.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: actionRow.activated()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: actionRow.glyph
        color: actionRow.glyphColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.font.icon * 1.3
        horizontalAlignment: Text.AlignHCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.label
          color: actionRow.labelColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: actionRow.wrap ? Text.WordWrap : Text.NoWrap
          elide: actionRow.wrap ? Text.ElideNone : Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: actionRow.caption !== ""
          text: actionRow.caption
          color: actionRow.captionColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: actionRow.wrap ? Text.WrapAtWordBoundaryOrAnywhere : Text.NoWrap
          elide: actionRow.wrap ? Text.ElideNone : Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: actionRow.hint !== ""
        text: actionRow.hint
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        visible: actionRow.chevron
        text: "›"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
