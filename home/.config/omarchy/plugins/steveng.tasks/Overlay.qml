import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// The board: steveng.tasks' overlay entry point (kind "overlay" — the
// clipboard manager's and emoji picker's shape). One card over a scrim,
// exclusive keyboard focus, toggled by `omarchy-shell shell toggle
// steveng.tasks` from a Hyprland bind. Folders on the left, the selected
// folder's stack on the right, a capture row at the bottom.
//
// Filing is the point of this surface: drag a task row onto a folder (or
// onto Stack to unfile it), or press `m` and pick the folder by cursor or
// digit. Filing is a retag through the service — a folder is a tag — so
// the server needs nothing new. Reordering inside a folder is NOT here:
// the server stores no rank, and pretending to reorder client-side would
// lie after the next refresh. Newest-first by seq is the only order.
//
// State and network live in the service (Service.qml, one per shell); the
// shell's panel loader hands it over as `service`. This file renders and
// forwards input, exactly like the bar face.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var service: null
  property bool opened: false

  // The [menu] surface tokens, like the clipboard: themes that style the
  // menu style this board.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: Util.alpha(foreground, 0.6)
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.heading + Style.spacing.controlPaddingY * 2)
  readonly property int contentSpacing: Style.spacing.md
  readonly property int cardWidth: Math.min(Style.space(900), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(620), panel.height - Style.gapsOut * 2)
  readonly property int rowHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int folderColumnWidth: Style.space(220)

  // ------------------------------------------------------------- model

  readonly property bool loggedOut: !service || service.openCount === -1
  readonly property bool hasData: service !== null && service.panelData !== null
  readonly property var folders: service ? service.folderList()
    : [{ name: "", label: "Stack", tasks: [], pending: false }]

  // "" is the stack. The name survives refreshes; a folder that empties
  // out falls back to the stack.
  property string selectedFolder: ""
  readonly property int folderIndex: {
    for (var i = 0; i < folders.length; i++)
      if (folders[i].name === selectedFolder) return i
    return 0
  }
  readonly property var tasks: folders[folderIndex].tasks
  property int taskIndex: 0
  readonly property int effectiveTaskIndex: Math.max(0, Math.min(taskIndex, tasks.length - 1))
  readonly property var currentTask: tasks.length > 0 ? tasks[effectiveTaskIndex] : null

  // "tasks" or "folders": which column j/k drives.
  property string focusColumn: "tasks"
  // m: the current task is being refiled; the folder column picks where.
  property bool moveMode: false
  property int moveTarget: 0
  property bool folderInputOpen: false

  // Drag state: the row pressed, and where the ghost started (it only
  // shows once the pointer has actually travelled, so a click stays a
  // click).
  property var dragTask: null
  property real dragStartX: 0
  property real dragStartY: 0

  // ------------------------------------------------------- shell contract

  function open(payloadJson) {
    root.opened = true
    root.moveMode = false
    root.folderInputOpen = false
    root.focusColumn = "tasks"
    root.dragTask = null
    if (root.service) root.service.panelOpened()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    root.moveMode = false
    root.dragTask = null
    if (root.service) root.service.panelClosed()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // ------------------------------------------------------------ actions

  function selectFolder(i) {
    if (i < 0 || i >= folders.length) return
    root.selectedFolder = folders[i].name
    root.taskIndex = 0
  }

  function moveCursor(delta) {
    if (root.moveMode) {
      root.moveTarget = Math.max(0, Math.min(folders.length - 1, root.moveTarget + delta))
    } else if (root.focusColumn === "folders") {
      root.selectFolder(Math.max(0, Math.min(folders.length - 1, root.folderIndex + delta)))
    } else {
      root.taskIndex = Math.max(0, Math.min(tasks.length - 1, root.effectiveTaskIndex + delta))
    }
  }

  function doneCurrent() {
    if (!root.currentTask || !root.service) return
    root.service.markDone(root.currentTask.seq, root.currentTask.version)
  }

  function beginMove() {
    if (!root.currentTask) { root.flash("Nothing to move here — pick a task first (0 is the stack)"); return }
    root.moveMode = true
    root.moveTarget = root.folderIndex
  }

  function commitMove(i) {
    if (root.moveMode && i >= 0 && i < folders.length) root.fileTask(root.currentTask, folders[i].name)
    root.moveMode = false
  }

  // The one mutation this board owns: refile `task` into `folderName`
  // ("" = the stack). A no-op when it is already there.
  function fileTask(task, folderName) {
    if (!task || !root.service) return
    var current = task.tags && task.tags.length > 0 ? task.tags[0] : ""
    if (current === folderName) return
    console.log("steveng.tasks: file seq " + task.seq + " -> " + (folderName === "" ? "stack" : folderName))
    root.service.moveTask(task.seq, task.version, folderName)
  }

  function endDrag() {
    if (root.dragTask !== null) {
      var moved = ghost.visible
      var action = ghost.Drag.drop()
      if (moved) console.log("steveng.tasks: drag of seq " + root.dragTask.seq
        + (action === Qt.IgnoreAction ? " released over nothing" : " dropped"))
    }
    root.dragTask = null
  }

  function refresh() {
    if (!root.service) return
    root.service.fetchPanel()
    root.service.refresh()
  }

  function capture(text) {
    var t = String(text).trim()
    var tag = root.selectedFolder
    if (t.charAt(0) === "#") {
      var sp = t.indexOf(" ")
      if (sp > 1) {
        tag = t.slice(1, sp)
        t = t.slice(sp + 1).trim()
      }
    }
    if (t === "" || !root.service) return
    root.service.addTask(t, tag)
  }

  property string flashText: ""
  function flash(text, ms) {
    root.flashText = text
    flashTimer.interval = ms === undefined ? 2500 : ms
    flashTimer.restart()
  }
  Timer { id: flashTimer; interval: 2500; onTriggered: root.flashText = "" }

  // A refused write, in the server's words, lands in the footer.
  Connections {
    target: root.service
    function onLastErrorChanged() {
      if (root.service && root.service.lastError !== "") root.flash(root.service.lastError, 6000)
    }
  }

  function hintText() {
    if (root.flashText !== "") return root.flashText
    if (root.loggedOut) return "Log in from the bar widget"
    if (root.moveMode) return "Move to:  j/k or 0–9 pick  ·  Enter confirm  ·  Esc cancel"
    return "j/k move  ·  Tab column  ·  0–9 folder  ·  d done  ·  m move  ·  n new  ·  f folder  ·  r refresh  ·  Esc"
  }

  function handleKey(event) {
    var k = event.key
    var digit = k >= Qt.Key_0 && k <= Qt.Key_9 ? k - Qt.Key_0 : -1

    if (k === Qt.Key_Escape) {
      if (root.moveMode) root.moveMode = false
      else root.close()
      return true
    }
    if (root.moveMode) {
      if (k === Qt.Key_J || k === Qt.Key_Down) { root.moveCursor(1); return true }
      if (k === Qt.Key_K || k === Qt.Key_Up) { root.moveCursor(-1); return true }
      if (k === Qt.Key_Return || k === Qt.Key_Enter) { root.commitMove(root.moveTarget); return true }
      if (digit >= 0) { root.commitMove(digit); return true }
      return true
    }
    if (root.loggedOut) return false

    if (k === Qt.Key_J || k === Qt.Key_Down) { root.moveCursor(1); return true }
    if (k === Qt.Key_K || k === Qt.Key_Up) { root.moveCursor(-1); return true }
    if (k === Qt.Key_Tab || k === Qt.Key_Backtab || k === Qt.Key_H || k === Qt.Key_L
        || k === Qt.Key_Left || k === Qt.Key_Right) {
      root.focusColumn = root.focusColumn === "tasks" ? "folders" : "tasks"
      return true
    }
    if (k === Qt.Key_Return || k === Qt.Key_Enter) {
      if (root.focusColumn === "folders") root.focusColumn = "tasks"
      return true
    }
    if (k === Qt.Key_Home) { root.taskIndex = 0; return true }
    if (k === Qt.Key_End) { root.taskIndex = Math.max(0, tasks.length - 1); return true }
    if (digit >= 0) { root.selectFolder(digit); return true }
    if (k === Qt.Key_D || k === Qt.Key_Delete) { root.doneCurrent(); return true }
    if (k === Qt.Key_M) { root.beginMove(); return true }
    if (k === Qt.Key_N || k === Qt.Key_Slash) { captureInput.forceActiveFocus(); return true }
    if (k === Qt.Key_F) {
      root.folderInputOpen = true
      Qt.callLater(function() { folderInput.forceActiveFocus() })
      return true
    }
    if (k === Qt.Key_R) { root.refresh(); return true }
    return false
  }

  onFoldersChanged: {
    // A folder that vanished (its last task moved out or was done) must
    // not leave a dangling move target.
    if (root.moveTarget >= folders.length) root.moveTarget = Math.max(0, folders.length - 1)
  }

  // ------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-tasks"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.handleKey(event)) event.accepted = true
        }

        Column {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: root.contentSpacing

          // ---------------------------------------------------- header
          Item {
            width: parent.width
            height: root.headerHeight

            Text {
              id: headerTitle
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf0ae  Tasks"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: headerTitle.right
              anchors.leftMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              text: root.service ? root.service.heroMeta() : "Service not mounted"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.moveMode
              text: "MOVE"
              color: root.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          // ------------------------------------------------------ body
          Item {
            id: body
            width: parent.width
            height: parent.height - root.headerHeight - captureRow.height - hintLine.height - root.contentSpacing * 3

            // ---- folders
            Item {
              id: folderColumn
              width: root.folderColumnWidth
              height: parent.height
              anchors.left: parent.left
              clip: true

              Column {
                id: folderList
                width: parent.width
                spacing: Style.space(3)

                Repeater {
                  model: root.folders

                  Rectangle {
                    id: folderRow
                    required property int index
                    required property var modelData

                    readonly property bool isSelected: index === root.folderIndex
                    readonly property bool isTarget: root.moveMode && index === root.moveTarget
                    readonly property bool lit: isTarget || dropZone.containsDrag

                    width: folderList.width - root.contentSpacing
                    height: root.rowHeight
                    radius: root.cornerRadius
                    // The theme's own selection tint (menu.selected-background,
                    // 8% foreground by default) marks the cursor; hover and the
                    // unfocused selection are fainter foreground washes. Never
                    // re-alpha selectedBackground: the accent-colored selected
                    // text is only readable on the theme's tint.
                    color: lit || (isSelected && root.focusColumn === "folders") ? root.selectedBackground
                      : isSelected ? Util.alpha(root.foreground, 0.05)
                      : folderMouse.containsMouse ? Util.alpha(root.foreground, 0.04)
                      : "transparent"
                    border.color: lit ? root.accent : "transparent"
                    border.width: lit ? Math.max(1, Style.normalBorderWidth) : 0

                    Text {
                      id: folderDigit
                      textFormat: Text.PlainText
                      visible: root.moveMode && folderRow.index <= 9
                      text: visible ? String(folderRow.index) : ""
                      color: folderRow.lit ? root.selectedText : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      textFormat: Text.PlainText
                      // \uf0ae list-check for the stack, \uf07b folder.
                      text: (folderRow.index === 0 ? "\uf0ae  " : "\uf07b  ") + folderRow.modelData.label
                      color: folderRow.lit || (folderRow.isSelected && root.focusColumn === "folders")
                        ? root.selectedText : root.foreground
                      // A pending folder reads exactly like a real one — a
                      // dimmed row looked disabled, and it is the opposite:
                      // it is the row waiting for a drop.
                      opacity: 1.0
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      elide: Text.ElideRight
                      anchors.left: folderDigit.visible ? folderDigit.right : parent.left
                      anchors.leftMargin: folderDigit.visible ? Style.space(8) : Style.space(10)
                      anchors.right: folderCount.left
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      id: folderCount
                      textFormat: Text.PlainText
                      text: folderRow.modelData.pending ? "new" : String(folderRow.modelData.tasks.length)
                      color: folderRow.modelData.pending ? root.accent
                        : folderRow.lit || (folderRow.isSelected && root.focusColumn === "folders")
                        ? root.selectedText : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    MouseArea {
                      id: folderMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (root.moveMode) root.commitMove(folderRow.index)
                        else { root.selectFolder(folderRow.index); root.focusColumn = "folders" }
                        keyCatcher.forceActiveFocus()
                      }
                    }

                    DropArea {
                      id: dropZone
                      anchors.fill: parent
                      onDropped: function(drop) {
                        var t = drop.source ? drop.source.task : null
                        if (t) root.fileTask(t, folderRow.modelData.name)
                        drop.accept()
                      }
                    }
                  }
                }

                // The "+ folder" affordance: a name typed here becomes a
                // pending folder to drop into; it turns real when a task
                // lands in it (a folder is a tag — an empty one is not
                // stored anywhere).
                Rectangle {
                  width: folderList.width - root.contentSpacing
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: root.folderInputOpen ? Util.alpha(root.foreground, 0.05) : "transparent"
                  visible: !root.loggedOut

                  Text {
                    visible: !root.folderInputOpen
                    textFormat: Text.PlainText
                    text: "\uf067  folder"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  MouseArea {
                    anchors.fill: parent
                    visible: !root.folderInputOpen
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.folderInputOpen = true
                      Qt.callLater(function() { folderInput.forceActiveFocus() })
                    }
                  }

                  TextInput {
                    id: folderInput
                    visible: root.folderInputOpen
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    clip: true
                    onAccepted: {
                      var name = root.service ? root.service.normalizeFolder(text) : text.trim()
                      text = ""
                      root.folderInputOpen = false
                      // Stay where the tasks are: switching into the new,
                      // empty folder left nothing under the cursor to `m`
                      // or drag — the way the first real attempt failed.
                      if (name !== "" && root.service) root.service.ensureFolder(name)
                      keyCatcher.forceActiveFocus()
                    }
                    Keys.onEscapePressed: {
                      text = ""
                      root.folderInputOpen = false
                      keyCatcher.forceActiveFocus()
                    }

                    Text {
                      visible: folderInput.text === ""
                      textFormat: Text.PlainText
                      text: "folder name (a-z, 0-9, -)…"
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }

            Rectangle {
              id: divider
              anchors.left: folderColumn.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.normalBorderWidth
              color: Util.alpha(root.border, 0.28)
            }

            // ---- the selected folder's stack
            Item {
              anchors.left: divider.right
              anchors.leftMargin: root.contentMargin
              anchors.right: parent.right
              height: parent.height
              clip: true

              ListView {
                id: taskList
                anchors.fill: parent
                model: root.tasks
                clip: true
                spacing: Style.space(3)
                boundsBehavior: Flickable.StopAtBounds
                currentIndex: root.effectiveTaskIndex
                highlightFollowsCurrentItem: false
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                delegate: Rectangle {
                  id: taskRow
                  required property int index
                  required property var modelData

                  readonly property bool hasCursor: index === root.effectiveTaskIndex
                    && (root.focusColumn === "tasks" || root.moveMode)
                  readonly property bool isMoving: root.moveMode && index === root.effectiveTaskIndex
                  readonly property string due: root.service ? root.service.dueSide(modelData) : ""

                  width: ListView.view.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: hasCursor ? root.selectedBackground
                    : rowMouse.containsMouse ? Util.alpha(root.foreground, 0.04)
                    : "transparent"
                  border.color: isMoving ? root.accent : "transparent"
                  border.width: isMoving ? Math.max(1, Style.normalBorderWidth) : 0

                  // The drag surface sits UNDER the done button, so the
                  // button keeps its click and everything else on the row
                  // is grabbable. preventStealing keeps the ListView from
                  // turning a vertical drag into a flick.
                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: root.dragTask !== null ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    drag.target: ghost
                    drag.axis: Drag.XAndYAxis
                    drag.threshold: 6
                    drag.smoothed: false
                    onPressed: function(mouse) {
                      root.taskIndex = taskRow.index
                      root.focusColumn = "tasks"
                      root.moveMode = false
                      var p = mapToItem(card, mouse.x, mouse.y)
                      root.dragStartX = p.x - Style.space(12)
                      root.dragStartY = p.y - root.rowHeight / 2
                      ghost.x = root.dragStartX
                      ghost.y = root.dragStartY
                      root.dragTask = taskRow.modelData
                      keyCatcher.forceActiveFocus()
                    }
                    onReleased: root.endDrag()
                    onCanceled: root.dragTask = null
                  }

                  PanelActionButton {
                    id: doneBtn
                    iconText: "\uf058"
                    tooltipText: "Mark done (d)"
                    foreground: taskRow.hasCursor ? root.selectedText : root.muted
                    hoverColor: root.accent
                    fontFamily: root.fontFamily
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: if (root.service) root.service.markDone(taskRow.modelData.seq, taskRow.modelData.version)
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: taskRow.modelData.title
                    color: taskRow.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    elide: Text.ElideRight
                    anchors.left: doneBtn.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: dueLabel.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: dueLabel
                    textFormat: Text.PlainText
                    text: taskRow.due
                    color: taskRow.due === "overdue" ? root.urgent
                      : taskRow.hasCursor ? root.selectedText : root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: taskRow.due === "overdue"
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              Column {
                anchors.centerIn: parent
                spacing: Style.space(8)
                width: parent.width
                visible: root.loggedOut || !root.hasData || root.tasks.length === 0

                Text {
                  textFormat: Text.PlainText
                  text: root.loggedOut ? "\uf084" : "\uf0ae"
                  color: root.selectedText
                  opacity: 0.8
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                  horizontalAlignment: Text.AlignHCenter
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.loggedOut ? "Not logged in"
                    : !root.hasData ? (root.service && root.service.loading ? "Fetching tasks…" : "No data yet")
                    : root.folderIndex === 0 ? "Stack empty — press n to capture"
                    : "Nothing filed here — drag a task in, or press n"
                  color: root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  horizontalAlignment: Text.AlignHCenter
                  width: parent.width
                }

                Button {
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: root.loggedOut
                  text: "Log in with Authentik"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: {
                    if (root.service) root.service.startLogin()
                    root.close()
                  }
                }
              }
            }
          }

          // --------------------------------------------------- capture
          BorderSurface {
            id: captureRow
            width: parent.width
            height: root.rowHeight
            radius: root.cornerRadius
            visible: !root.loggedOut
            color: Style.normalFillFor(root.foreground, root.accent)
            borderSpec: Border.controlSpec(
              captureInput.activeFocus ? "focus" : "normal", root.foreground, root.accent)

            Text {
              id: capturePlus
              textFormat: Text.PlainText
              text: "\uf067"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            TextInput {
              id: captureInput
              anchors.left: capturePlus.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              clip: true
              selectByMouse: true
              onAccepted: {
                root.capture(text)
                text = ""
              }
              Keys.onEscapePressed: {
                text = ""
                keyCatcher.forceActiveFocus()
              }

              Text {
                visible: captureInput.text === "" && !captureInput.activeFocus
                textFormat: Text.PlainText
                text: root.folderIndex === 0
                  ? "New task on the stack…  (n; #folder title files it)"
                  : "New task in " + root.folders[root.folderIndex].label + "…  (n)"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
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

          // ------------------------------------------------------ hints
          Text {
            id: hintLine
            width: parent.width
            textFormat: Text.PlainText
            text: root.hintText()
            color: root.moveMode || root.flashText !== "" ? root.selectedText : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }

      // The row that travels with the pointer. Its hotspot is where the
      // pointer sits, so the DropArea under the pointer is the one lit.
      Rectangle {
        id: ghost
        z: 100
        width: Math.min(Style.space(280), card.width * 0.4)
        height: root.rowHeight
        radius: root.cornerRadius
        color: root.background
        border.color: root.accent
        border.width: Math.max(1, Style.normalBorderWidth)
        opacity: 0.95
        property var task: root.dragTask
        visible: root.dragTask !== null
          && (Math.abs(x - root.dragStartX) + Math.abs(y - root.dragStartY)) > 6
        Drag.active: root.dragTask !== null
        Drag.hotSpot.x: Style.space(12)
        Drag.hotSpot.y: height / 2

        Text {
          textFormat: Text.PlainText
          text: ghost.task ? ghost.task.title : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          elide: Text.ElideRight
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }
}
