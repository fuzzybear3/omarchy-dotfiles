import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

// The personal tasks service's bar presence: the count of open tasks due
// today or overdue, polled through `omarchy-tasks count` (the same script the
// keybinding uses, so the bar and the terminal cannot disagree about the
// server or the token).
//
// Logged OUT the bar face is a dimmed key and clicking opens a small popup
// holding one Login button. The button runs the device flow HEADLESSLY —
// `omarchy-tasks login` opens the approval page in the browser and reports
// through notifications, no terminal involved — and a short poll flips the
// widget to the count as soon as the approval lands. Logged IN a click
// captures a task; at zero due the widget hides (the quiet state);
// unreachable it dims the last count to an em-dash.
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — the japanquake plugin's convention.)
Ui.Panel {
  id: root
  moduleName: "steveng.tasks"
  ipcTarget: "steveng.tasks"

  // -1: not logged in; otherwise the last count read.
  property int dueCount: -1
  property bool reachable: true
  readonly property bool loggedOut: dueCount === -1

  visible: loggedOut || dueCount > 0 || (dueCount >= 0 && !reachable)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!countProc.running) countProc.running = true
  }

  function startLogin() {
    root.close()
    if (!loginProc.running) loginProc.running = true
    loginPoll.remaining = 18
    loginPoll.restart()
  }

  Process {
    id: countProc
    command: ["omarchy-tasks", "count"]
    stdout: StdioCollector { id: countOut }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        const n = parseInt(countOut.text.trim(), 10)
        root.reachable = true
        root.dueCount = isNaN(n) ? 0 : n
        loginPoll.stop()
      } else if (exitCode === 3) {
        root.dueCount = -1
      } else {
        // A token exists but the server is unreachable (off-tailnet, or the
        // service is down): keep the last count, dimmed.
        root.reachable = false
        loginPoll.stop()
      }
    }
  }

  // The device flow itself: opens the browser, polls the token endpoint, and
  // reports success or failure through notifications (the script's job).
  Process {
    id: loginProc
    command: ["omarchy-tasks", "login"]
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Armed by the Login button: the flow takes as long as the browser
  // approval does, so poll every 10s for up to three minutes instead of
  // leaving the key stuck until the next minute tick.
  Timer {
    id: loginPoll
    property int remaining: 0
    interval: 10000
    repeat: true
    onTriggered: {
      root.refresh()
      if (--remaining <= 0) stop()
    }
  }

  // Capture may have added a due task; read back shortly after the prompt
  // closes rather than waiting out the minute.
  Timer {
    id: readback
    interval: 15000
    repeat: false
    onTriggered: root.refresh()
  }

  Ui.WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    opacity: (root.loggedOut || !root.reachable) ? 0.45 : 1.0
    //  is the nerd-font key (log in);  the list-check the count
    // rides beside, in the bar font — the KeyboardLayout text convention.
    // Escapes, not literal glyphs: a literal PUA character has already been
    // eaten once by an edit-tool round trip, leaving an empty string and an
    // invisible widget that still reserved its slot.
    text: root.loggedOut
      ? "\uf084"
      : "\uf0ae " + (root.reachable ? root.dueCount : "–")
    tooltipText: root.loggedOut
      ? "Personal tasks — not logged in"
      : root.reachable
        ? "Tasks due today (click to capture)"
        : "Tasks service unreachable — showing the last known state"
    onPressed: {
      if (root.loggedOut) {
        root.toggle()
      } else if (root.bar) {
        root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-tasks capture")
        readback.restart()
      }
    }
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: Style.space(280)
    contentHeight: loginColumn.implicitHeight + Style.spacing.popupPadding

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.startLogin()
    }

    Column {
      id: loginColumn
      width: parent.width
      spacing: Style.spacing.md

      Ui.PanelHero {
        width: parent.width
        iconComponent: null
        title: "Tasks"
        detail: "Not logged in"
      }

      Ui.Button {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Log in with Authentik"
        bordered: true
        onClicked: root.startLogin()
      }
    }
  }
}
