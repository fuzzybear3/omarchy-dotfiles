import QtQuick
import Quickshell.Io

// The one-per-shell half of steveng.tasks (kind "service" — the gitea
// tracker's shape, which is the media plugin's shape). The bar instantiates
// one BarWidget per monitor; they all bind to this single instance through
// bar.shell.serviceFor("steveng.tasks"), so the faces and panels cannot
// disagree, and the tasks API is polled exactly once per tick no matter how
// many monitors are connected. omarchy-tasks' own login flock stays as the
// second line of defense — it also covers a login run from a terminal.
Item {
  id: service
  visible: false

  // Injected by shell.qml when the service is mounted.
  property var shell: null

  // Bar-face state, from `count`. -1: not logged in.
  property int dueCount: -1
  property bool reachable: true
  readonly property bool loggedOut: dueCount === -1

  // Panel state, from `panel`: {date, today: [], inbox: []}. null until a
  // panel first opens.
  property var panelData: null
  property bool loading: false

  // How many panels are open across monitors.
  property int openPanels: 0

  // Pending action arguments; the Process commands bind to these (the gitea
  // runProc idiom — a Process command cannot take call arguments).
  property int doneSeq: 0
  property int doneVersion: 0
  property string addTitle: ""

  // One line at mount: seeing it once in the journal — with two monitors —
  // is the proof the service pattern took.
  Component.onCompleted: console.log("steveng.tasks: service mounted (single instance)")

  // ------------------------------------------------------------ lifecycle

  function panelOpened() {
    fetchPanel()
    refresh()
    openPanels++
  }

  function panelClosed() {
    openPanels = Math.max(0, openPanels - 1)
  }

  // ------------------------------------------------------------- fetching

  function refresh() {
    if (!countProc.running) countProc.running = true
  }

  function fetchPanel() {
    loading = true
    if (!panelProc.running) panelProc.running = true
  }

  // -------------------------------------------------------------- actions

  // The device flow, headless: the script opens the browser and reports
  // through notifications; the poll flips the face once the approval lands.
  function startLogin() {
    if (!loginProc.running) loginProc.running = true
    loginPoll.remaining = 18
    loginPoll.restart()
  }

  function markDone(seq, version) {
    if (doneProc.running) return
    doneSeq = seq
    doneVersion = version
    doneProc.running = true
  }

  function addTask(title) {
    title = String(title).trim()
    if (title === "" || addProc.running) return
    addTitle = title
    addProc.running = true
  }

  // Armed by the widgets after a floating-terminal capture: the prompt may
  // have added a due task, so read back shortly after it closes.
  function scheduleReadback() {
    readback.restart()
  }

  // ------------------------------------------------------ shared helpers

  function dueSide(t) {
    if (!t.due) return ""
    if (!panelData) return t.due
    if (t.due < panelData.date) return "overdue"
    if (t.due === panelData.date) return "today"
    return t.due
  }

  function heroMeta() {
    if (loggedOut) return "Not logged in"
    if (!reachable) return "Unreachable — last known state"
    var parts = []
    parts.push(dueCount === 0 ? "nothing due today" : dueCount + " due today")
    if (panelData && panelData.inbox.length > 0)
      parts.push(panelData.inbox.length + " in the inbox")
    if (loading) parts.push("refreshing…")
    return parts.join(" · ")
  }

  // ------------------------------------------------------------ processes

  Process {
    id: countProc
    command: ["omarchy-tasks", "count"]
    stdout: StdioCollector { id: countOut }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        const n = parseInt(countOut.text.trim(), 10)
        service.reachable = true
        service.dueCount = isNaN(n) ? 0 : n
        loginPoll.stop()
      } else if (exitCode === 3) {
        service.dueCount = -1
      } else {
        // A token exists but the server is unreachable (off-tailnet, or the
        // service is down): keep the last count, dimmed by the faces.
        service.reachable = false
        loginPoll.stop()
      }
    }
  }

  Process {
    id: panelProc
    command: ["omarchy-tasks", "panel"]
    stdout: StdioCollector { id: panelOut }
    onExited: function(exitCode) {
      service.loading = false
      if (exitCode === 0) {
        try {
          service.panelData = JSON.parse(panelOut.text)
          service.reachable = true
        } catch (e) {
          service.reachable = false
        }
      } else if (exitCode === 3) {
        service.dueCount = -1
      } else {
        service.reachable = false
      }
    }
  }

  Process {
    id: loginProc
    command: ["omarchy-tasks", "login"]
  }

  Process {
    id: doneProc
    command: ["omarchy-tasks", "done", String(service.doneSeq), String(service.doneVersion)]
    onExited: function() {
      service.fetchPanel()
      service.refresh()
    }
  }

  Process {
    id: addProc
    command: ["omarchy-tasks", "add", service.addTitle]
    onExited: function() {
      service.fetchPanel()
      service.refresh()
    }
  }

  // --------------------------------------------------------------- timers

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      service.refresh()
      if (service.openPanels > 0) service.fetchPanel()
    }
  }

  // Armed by the Login button: the flow takes as long as the browser
  // approval does, so poll every 10s for up to three minutes instead of
  // leaving the face stuck until the next minute tick.
  Timer {
    id: loginPoll
    property int remaining: 0
    interval: 10000
    repeat: true
    onTriggered: {
      service.refresh()
      if (service.openPanels > 0) service.fetchPanel()
      if (--remaining <= 0) stop()
    }
  }

  Timer {
    id: readback
    interval: 15000
    repeat: false
    onTriggered: {
      service.refresh()
      if (service.openPanels > 0) service.fetchPanel()
    }
  }
}
