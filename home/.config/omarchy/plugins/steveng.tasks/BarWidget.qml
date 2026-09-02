import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui as Ui

// The per-monitor half of steveng.tasks: a thin view over the plugin's
// service instance (Service.qml, mounted once by the shell regardless of
// monitor count) reached through bar.shell.serviceFor — the gitea tracker's
// dual-monitor shape. All polling, timers, and state live in the service;
// this file only renders and forwards input.
//
// The bar face is the list-check with the due count (a dimmed key when
// logged out). Clicking opens an anchored panel: logged out it holds one
// Login button running the device flow headlessly; logged in it shows the
// STACK (open untagged tasks, newest on top — a stack, not a calendar),
// one folder per tag, and an inline capture row ("#folder title" files it).
// The SUPER+SHIFT+T floating-terminal capture is untouched.
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — the japanquake plugin's convention.)
Ui.Panel {
  id: root
  moduleName: "steveng.tasks"
  ipcTarget: "steveng.tasks"

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("steveng.tasks") : null

  // Null-safe proxies: the service mounts at shell startup, but bindings
  // evaluate before it lands, and a broken mount must degrade to a dimmed
  // glyph rather than a wall of TypeErrors.
  readonly property int openCount: svc ? svc.openCount : -1
  readonly property bool reachable: svc ? svc.reachable : true
  readonly property bool loggedOut: openCount === -1
  readonly property var panelData: svc ? svc.panelData : null
  readonly property bool loading: svc ? svc.loading : false

  // The gitea/system-monitor panel color recipe, so side-by-side panels match.
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color muted: Qt.darker(foreground, 1.4)
  readonly property color trackColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function dueSide(t) { return svc ? svc.dueSide(t) : "" }

  onOpenedChanged: {
    if (!svc) return
    if (opened) svc.panelOpened()
    else svc.panelClosed()
  }

  // A widget destroyed with its panel open (monitor unplugged) must not
  // strand the service's open-panel count.
  Component.onDestruction: if (opened && svc) svc.panelClosed()

  Ui.WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    opacity: (root.loggedOut || !root.reachable) ? 0.45 : 1.0
    // \uf084 is the nerd-font key (log in); \uf0ae the list-check the count
    // rides beside. Escapes, not literal glyphs: a literal PUA character has
    // already been eaten once by an edit-tool round trip.
    text: root.loggedOut
      ? "\uf084"
      : "\uf0ae " + (root.reachable ? root.openCount : "–")
    tooltipText: root.loggedOut
      ? "Personal tasks — not logged in"
      : root.reachable
        ? "Open tasks on the stack — click for the panel"
        : "Tasks service unreachable — showing the last known state"
    onPressed: root.toggle()
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: {
        if (root.loggedOut) {
          if (root.svc) root.svc.startLogin()
          root.close()
        } else {
          captureInput.forceActiveFocus()
        }
      }
      onTextKey: function(text) {
        if (text === "r" || text === "R") {
          if (root.svc) { root.svc.fetchPanel(); root.svc.refresh() }
        }
      }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(9)

        Ui.PanelHero {
          width: parent.width
          title: "Tasks"
          meta: root.svc ? root.svc.heroMeta() : "Service not mounted"
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              text: root.loggedOut ? "\uf084" : "\uf0ae"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            Ui.PanelActionButton {
              iconText: "\uf021"
              tooltipText: "Refresh (R)"
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              visible: !root.loggedOut
              onClicked: if (root.svc) { root.svc.fetchPanel(); root.svc.refresh() }
            }
          }
        }

        // ---------- Logged out: the one button ----------
        Ui.Button {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.loggedOut
          text: "Log in with Authentik"
          bordered: true
          onClicked: {
            if (root.svc) root.svc.startLogin()
            root.close()
          }
        }

        Ui.PanelSeparator { foreground: root.foreground; visible: !root.loggedOut }

        // ---------- The stack ----------
        Column {
          width: parent.width
          spacing: Style.space(3)
          visible: !root.loggedOut

          SectionHeading {
            title: "STACK"
            value: root.panelData ? String(root.panelData.stack.length) : ""
          }

          Text {
            visible: root.panelData !== null && root.panelData.stack.length === 0
            text: "Stack empty — capture something below"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.panelData ? root.panelData.stack : []
            TaskRow {
              required property var modelData
              task: modelData
            }
          }

          Text {
            visible: root.panelData === null
            text: root.loading ? "Fetching tasks…" : "No data yet"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Folders: one section per tag ----------
        Repeater {
          model: root.panelData ? root.panelData.folders : []

          Column {
            id: folderCol
            required property var modelData
            width: parent ? parent.width : 0
            spacing: Style.space(3)
            visible: !root.loggedOut

            Ui.PanelSeparator { foreground: root.foreground }

            SectionHeading {
              title: folderCol.modelData.name.toUpperCase()
              value: String(folderCol.modelData.tasks.length)
            }

            Repeater {
              model: folderCol.modelData.tasks
              TaskRow {
                required property var modelData
                task: modelData
              }
            }
          }
        }

        // ---------- Inline capture ----------
        Ui.BorderSurface {
          width: parent.width
          visible: !root.loggedOut
          height: Style.space(30)
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.foreground, root.accent)
          borderSpec: Border.controlSpec(
            captureInput.activeFocus ? "focus" : "normal", root.foreground, root.accent)

          Text {
            id: capturePlus
            text: "\uf067"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.left: parent.left
            anchors.leftMargin: Style.space(9)
            anchors.verticalCenter: parent.verticalCenter
          }

          TextInput {
            id: captureInput
            anchors.left: capturePlus.right
            anchors.leftMargin: Style.space(7)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(9)
            anchors.verticalCenter: parent.verticalCenter
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            clip: true
            selectByMouse: true
            onAccepted: {
              var t = text.trim()
              var tag = ""
              if (t.charAt(0) === "#") {
                var sp = t.indexOf(" ")
                if (sp > 1) {
                  tag = t.slice(1, sp)
                  t = t.slice(sp + 1).trim()
                }
              }
              if (root.svc) root.svc.addTask(t, tag)
              text = ""
            }
            Keys.onEscapePressed: {
              text = ""
              keyCatcher.forceActiveFocus()
            }

            Text {
              visible: captureInput.text === "" && !captureInput.activeFocus
              text: "New task…  (#folder title files it)"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            visible: !captureInput.activeFocus
            cursorShape: Qt.IBeamCursor
            onClicked: captureInput.forceActiveFocus()
          }
        }
      }
    }
  }

  // ---------- Local components, in the gitea panel's dialect ----------

  component SectionHeading: Item {
    property string title: ""
    property string value: ""

    width: parent ? parent.width : 0
    implicitHeight: Math.max(headingText.implicitHeight, valueText.implicitHeight) + Style.space(4)

    Ui.PanelSectionHeader {
      id: headingText
      text: title
      textFormat: Text.PlainText
      foreground: root.foreground
      fontFamily: root.fontFamily
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.right: valueText.visible ? valueText.left : parent.right
      anchors.rightMargin: valueText.visible ? Style.space(8) : 0
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: valueText
      text: value
      visible: text !== ""
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component TaskRow: Rectangle {
    id: row
    property var task: null
    property bool overdue: false

    width: parent ? parent.width : 0
    height: Style.space(26)
    radius: Style.cornerRadius
    color: rowMouse.containsMouse ? root.trackColor : "transparent"

    Ui.PanelActionButton {
      id: doneBtn
      iconText: "\uf058"
      tooltipText: "Mark done"
      foreground: root.muted
      hoverColor: root.accent
      fontFamily: root.fontFamily
      anchors.left: parent.left
      anchors.leftMargin: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter
      onClicked: if (root.svc && row.task) root.svc.markDone(row.task.seq, row.task.version)
    }

    Text {
      text: row.task ? row.task.title : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      anchors.left: doneBtn.right
      anchors.leftMargin: Style.space(6)
      anchors.right: sideLabel.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: sideLabel
      text: row.task ? root.dueSide(row.task) : ""
      color: row.overdue ? root.urgent : root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: row.overdue
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    Ui.PanelToolTip {
      visible: rowMouse.containsMouse && row.task && row.task.notes !== undefined
      text: row.task && row.task.notes ? row.task.notes : ""
      fontFamily: root.fontFamily
    }
  }
}
