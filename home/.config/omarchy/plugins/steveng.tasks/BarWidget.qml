import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

// The personal tasks service's bar presence: the count of open tasks due
// today or overdue, polled through `omarchy-tasks count` (the same script the
// keybinding uses, so the bar and the terminal cannot disagree about the
// server or the token).
//
// Three faces: logged OUT it shows a dimmed key — click to run the device-
// flow login in a floating terminal; logged in it shows the due count and a
// click captures a task; unreachable it dims the last count to an em-dash
// (fail gracefully, no local queue). At zero due it hides — the quiet state.
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — the japanquake plugin's convention.)
Ui.BarWidget {
  id: root
  moduleName: "steveng.tasks"

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
        // Not logged in: offer the key. loginPoll keeps watching after a
        // login click so the widget flips to the count without waiting out
        // the minute.
        root.dueCount = -1
      } else {
        // A token exists but the server is unreachable (off-tailnet, or the
        // service is down): keep the last count, dimmed.
        root.reachable = false
        loginPoll.stop()
      }
    }
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Armed by a login click: the device flow takes as long as the browser
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
    text: root.loggedOut
      ? ""
      : " " + (root.reachable ? root.dueCount : "–")
    tooltipText: root.loggedOut
      ? "Personal tasks — click to log in"
      : root.reachable
        ? "Tasks due today (click to capture)"
        : "Tasks service unreachable — showing the last known state"
    onPressed: {
      if (!root.bar) return
      if (root.loggedOut) {
        root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-tasks login")
        loginPoll.remaining = 18
        loginPoll.restart()
      } else {
        root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-tasks capture")
        readback.restart()
      }
    }
  }
}
