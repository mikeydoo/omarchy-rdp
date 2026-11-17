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

  // Problems worth showing. Before setup only the ones setup can't fix (no GPU render
  // node, an Omarchy change): the rest is simply "not installed yet".
  readonly property var shownProblems: svc.problems.filter(function(c) {
    return root.isSetUp || !c.fix
  })

  // Two-step rows for anything that closes windows: the first click arms, the second
  // (within a few seconds) does it.
  // A question from ask-close-other.sh ("log out the other session?"), shown in this panel
  // in place of its usual content: {title, body, answerFile}. The answer ("logout" or
  // "keep") is written to answerFile; closing the panel answers "keep".
  property var question: null
  readonly property bool asking: question !== null
  property bool questionWhy: false

  function answer(choice) {
    if (!question) return
    var file = String(question.answerFile)
    question = null
    Quickshell.execDetached(["sh", "-c", 'printf "%s" "$1" > "$2.tmp" && mv "$2.tmp" "$2"',
      "sh", choice, file])
    if (opened) close()
  }

  // The "why log out" note: collapsed until clicked (kept while the shell runs).
  property bool noteOpen: false

  property string armed: ""
  function confirmThen(name, action) {
    if (armed === name) { armed = ""; action() }
    else { armed = name; disarm.restart() }
  }
  Timer { id: disarm; interval: 4000; onTriggered: root.armed = "" }

  function metaText() {
    if (!svc.loaded) return strings.t("state.loading")
    if (inRemote) return strings.t("meta.remote")
    if (state === "connected") return strings.t("meta.connected")
    if (state === "ready") return strings.t("meta.ready")
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
    if (st.client) return strings.t("remote.connected").arg(st.client)
    var waiting = st.rdpActive ? strings.t("remote.waiting").arg(st.address || "") : strings.t("remote.rdpOff")
    if (!st.remoteActive) return strings.t("remote.stopped") + " · " + waiting
    return (st.remoteLocked === true ? strings.t("remote.locked") : strings.t("remote.running")) + " · " + waiting
  }

  // Shared mode: RDP shows the desk session itself, so there's no remote session.
  readonly property bool shared: !!st && st.mode === "shared"

  function deskCaption() {
    if (!st) return ""
    if (shared && st.client) return strings.t("desk.sharedWith").arg(st.client)
    if (shared && st.deskActive) {
      var waiting = st.rdpActive ? strings.t("remote.waiting").arg(st.address || "") : strings.t("remote.rdpOff")
      return (st.deskLocked === true ? strings.t("desk.locked") : strings.t("desk.inUse")) + " · " + waiting
    }
    if (!st.deskActive) return strings.t("desk.none")
    if (st.deskLocked === true) return strings.t("desk.locked")
    if (st.deskLocked === false) return strings.t("desk.inUse")
    return strings.t("desk.loggedIn")
  }

  readonly property var logins: st && Array.isArray(st.logins) ? st.logins : []

  // "Today 11:57", "Yesterday 18:02", "Mon 16 Nov 09:30".
  function whenText(epoch) {
    var d = new Date(epoch * 1000)
    var now = new Date((st && st.time ? st.time : Date.now() / 1000) * 1000)
    var day = function(x) { return new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime() }
    var diff = Math.round((day(now) - day(d)) / 86400000)
    var hm = Qt.formatTime(d, "HH:mm")
    if (diff === 0) return strings.t("when.today").arg(hm)
    if (diff === 1) return strings.t("when.yesterday").arg(hm)
    return Qt.formatDateTime(d, "ddd d MMM HH:mm")
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
    // Used by ask-close-other.sh; see `question`.
    function ask(title: string, body: string, answerFile: string): string {
      if (root.question) root.answer("keep")
      root.questionWhy = false
      root.question = { title: title, body: body, answerFile: answerFile }
      root.open()
      return "ok"
    }
    // The answer file of the question showing now, or "" (lets the asker notice a lost one).
    function pending(): string { return root.question ? String(root.question.answerFile) : "" }
    // Show the explanation of the question showing now, as its Why? button does.
    function why(): void { if (root.question) root.questionWhy = true }
  }

  onOpenedChanged: if (!opened && question) answer("keep")
  else if (opened) {
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
    contentHeight: panel.fittedContentHeight(root.asking ? questionColumn.implicitHeight : column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = t.toLowerCase()
        if (key === "r") svc.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: root.asking ? questionColumn.implicitHeight : column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // --- a question from ask-close-other.sh -------------------------------------------
        Column {
          id: questionColumn
          visible: root.asking
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.question ? String(root.question.title) : ""
            meta: strings.t("title")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              OpticalGlyph {
                width: Style.font.display
                height: Style.font.display
                text: root.glyph
                fontFamily: root.fontFamily
                fontSize: Style.font.display
                color: root.foreground
              }
            }
          }

          Text {
            visible: root.questionWhy
            textFormat: Text.PlainText
            width: parent.width
            text: root.question ? String(root.question.body) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            lineHeight: 1.15
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(6)

            Button {
              Layout.fillWidth: true
              text: strings.t("ask.logout")
              iconText: "\uf08b"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.answer("logout")
            }
            Button {
              Layout.fillWidth: true
              text: strings.t("ask.keep")
              iconText: "\uf00c"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.answer("keep")
            }
            Button {
              visible: !root.questionWhy
              Layout.fillWidth: true
              text: strings.t("ask.why")
              iconText: "\uf059"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.questionWhy = true
            }
          }
        }

        Column {
          id: column
          visible: !root.asking
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

          // --- sessions: the desk and the remote, the other one can be logged out ------------
          PanelSeparator {
            visible: root.isSetUp
            foreground: root.foreground
          }

          Column {
            visible: root.isSetUp
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: strings.t("section.sessions")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SessionRow {
              which: "desk"
              glyph: ""
              title: strings.t("desk.title")
              here: !root.inRemote
              active: !!root.st && root.st.deskActive
              caption: root.deskCaption()
              action: "logout-desk"
            }

            SessionRow {
              visible: !root.shared
              which: "remote"
              glyph: "󰢹"
              title: strings.t("remote.title")
              here: root.inRemote
              active: !!root.st && root.st.remoteActive
              caption: root.remoteCaption()
              captionColor: root.st && root.st.restartPending ? root.urgent : root.dim
              action: "logout-remote"
            }

            // Desk only: the remote session's other controls.
            ActionRow {
              visible: !root.inRemote && !!root.st && !!root.st.client
              glyph: ""
              label: strings.t("disconnect")
              caption: root.st ? strings.t("disconnect.caption").arg(root.st.client || "") : ""
              hint: svc.busy === "kick" ? strings.t("working") : ""
              onActivated: svc.run("kick", ["kick"])
            }

            ActionRow {
              visible: !root.inRemote && !root.shared && !!root.st && root.st.remoteActive
              glyph: ""
              label: root.armed === "restart" ? strings.t("confirm") : strings.t("restart")
              labelColor: root.armed === "restart" ? root.urgent : root.foreground
              caption: strings.t("restart.caption")
              hint: svc.busy === "restart-remote" ? strings.t("working") : ""
              onActivated: root.confirmThen("restart", function() { svc.run("restart-remote", ["restart-remote"]) })
            }

            // Desk only: share the desk session over RDP, or use a separate headless one.
            Item {
              id: modeRow
              visible: !root.inRemote
              width: parent.width
              implicitHeight: modeText.implicitHeight + Style.spacing.rowPaddingX
              readonly property bool leaving: !root.shared && !!root.st && root.st.remoteActive

              RowLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Text {
                  textFormat: Text.PlainText
                  text: "\udb80\udf79"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  Layout.alignment: Qt.AlignVCenter
                  Layout.preferredWidth: Style.font.icon * 1.3
                  horizontalAlignment: Text.AlignHCenter
                }

                ColumnLayout {
                  id: modeText
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.armed === "mode" ? strings.t("mode.confirm") : strings.t("mode.title")
                    color: root.armed === "mode" ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: svc.busy === "mode" ? strings.t("working")
                        : strings.t(root.shared ? "mode.shared" : "mode.headless")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                ToggleSwitch {
                  id: modeSwitch
                  Layout.alignment: Qt.AlignVCenter
                  checked: root.shared
                  busy: svc.busy === "mode"
                  foreground: root.foreground
                  onToggled: {
                    var target = checked ? "headless" : "shared"
                    var go = function() { svc.run("mode", ["mode", target]) }
                    // Leaving headless mode closes the remote session: click twice.
                    if (target === "shared" && modeRow.leaving) root.confirmThen("mode", go)
                    else go()
                  }
                }
              }
            }
          }

          // --- recent logins -------------------------------------------------------------
          PanelSeparator {
            visible: root.isSetUp
            foreground: root.foreground
          }

          Column {
            visible: root.isSetUp
            width: parent.width
            spacing: 0

            PanelSectionHeader {
              text: strings.t("section.logins")
              foreground: root.foreground
              fontFamily: root.fontFamily
              bottomPadding: Style.space(4)
            }

            Repeater {
              model: root.logins
              ActionRow {
                id: loginRow
                required property var modelData
                glyph: loginRow.modelData.kind === "rdp" ? "󰢹" : ""
                glyphColor: root.dim
                label: loginRow.modelData.kind === "rdp"
                  ? strings.t("login.rdp").arg(loginRow.modelData.from || "?")
                  : strings.t("login.desk")
                hint: root.whenText(loginRow.modelData.time)
                interactive: false
                compact: true
              }
            }

            Text {
              visible: root.logins.length === 0
              textFormat: Text.PlainText
              width: parent.width
              leftPadding: Style.space(10)
              text: strings.t("login.none")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // --- why log out the other session (separate sessions only) ---------------------
          PanelSeparator {
            visible: root.isSetUp && !root.shared
            foreground: root.foreground
          }

          RowLayout {
            visible: root.isSetUp && !root.shared
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
              Layout.alignment: root.noteOpen ? Qt.AlignTop : Qt.AlignVCenter
              Layout.leftMargin: Style.space(10)
              Layout.preferredWidth: Style.font.icon * 1.3
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              Layout.fillWidth: true
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: strings.t("note.title") + (root.noteOpen ? "  \u25be" : "  \u203a")
                color: noteMouse.containsMouse ? root.foreground : Qt.lighter(root.dim, 1.15)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                wrapMode: Text.WordWrap

                MouseArea {
                  id: noteMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.noteOpen = !root.noteOpen
                }
              }

              Text {
                visible: root.noteOpen
                textFormat: Text.PlainText
                width: parent.width
                text: strings.t("note.body")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                lineHeight: 1.15
              }
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

  // One session (desk or remote): its state, "this session" for the one you're in, and
  // LOG OUT (two clicks) for the other one while it's running.
  component SessionRow: ActionRow {
    id: sessionRow
    property string which: ""
    property string title: ""
    property bool here: false
    property bool active: false
    property string action: ""
    readonly property bool canLogOut: !here && active
    readonly property bool armedHere: root.armed === action

    label: armedHere ? strings.t("logoutConfirm").arg(title) : title
    labelColor: armedHere ? root.urgent : root.foreground
    glyphColor: active ? root.foreground : root.dim
    hint: here ? strings.t("thisSession")
      : svc.busy === action ? strings.t("working")
      : canLogOut ? strings.t("logOut") : ""
    hintColor: canLogOut ? (armedHere ? root.urgent : root.foreground) : root.dim
    interactive: canLogOut
    onActivated: root.confirmThen(action, function() { svc.run(sessionRow.action, [sessionRow.action]) })
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
    property color hintColor: root.dim
    property bool compact: false
    property bool chevron: false
    property bool wrap: true
    property bool interactive: true
    signal activated()

    width: parent ? parent.width : implicitWidth
    foreground: root.foreground
    hasCursor: interactive && rowMouse.containsMouse
    implicitHeight: rowContent.implicitHeight + (compact ? Style.space(6) : Style.spacing.rowPaddingX)

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
        color: actionRow.hintColor
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
