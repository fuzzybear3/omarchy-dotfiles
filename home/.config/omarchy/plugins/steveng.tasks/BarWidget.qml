import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

// The personal tasks service's bar presence: the count of open tasks due
// today or overdue, polled through `omarchy-tasks count` (the same script the
// keybinding uses, so the bar and the terminal cannot disagree about the
// server or the token). Quiet by design: hidden at zero and hidden until
// `omarchy-tasks login` has run; a reachability problem dims the last count
// to an em-dash rather than shouting. Clicking captures a task.
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — the japanquake plugin's convention.)
Ui.BarWidget {
  id: root
  moduleName: "steveng.tasks"

  // -1: not logged in (hidden); otherwise the last count read.
  property int dueCount: -1
  property bool reachable: true

  visible: dueCount > 0 || (dueCount >= 0 && !reachable)
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
      } else if (exitCode === 3) {
        // Not logged in: nothing to say. The widget reappears by itself on
        // the poll after `omarchy-tasks login`.
        root.dueCount = -1
      } else {
        // Logged in but the server is unreachable (off-tailnet, or the
        // service is down): keep the last count, dimmed (design: fail
        // gracefully, no local queue).
        root.reachable = false
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

  Ui.WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    opacity: root.reachable ? 1.0 : 0.45
    //  is the nerd-font list-check glyph; the count rides beside it in
    // the bar font, the KeyboardLayout text convention.
    text: " " + (root.reachable ? root.dueCount : "–")
    tooltipText: root.reachable
      ? "Tasks due today (click to capture)"
      : "Tasks service unreachable — showing the last known state"
    onPressed: {
      if (root.bar)
        root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-tasks capture")
      // The capture may have added a due task; read back shortly after the
      // prompt closes rather than waiting out the minute.
      readback.start()
    }
  }

  Timer {
    id: readback
    interval: 15000
    repeat: false
    onTriggered: root.refresh()
  }
}
