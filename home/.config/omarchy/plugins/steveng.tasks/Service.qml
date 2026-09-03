import QtQuick
import Quickshell.Io

// The one-per-shell half of steveng.tasks (kind "service" — the gitea
// tracker's shape, which is the media plugin's shape). The bar instantiates
// one BarWidget per monitor; they all bind to this single instance through
// bar.shell.serviceFor("steveng.tasks"), so the faces and panels cannot
// disagree, and the tasks API is polled exactly once per tick no matter how
// many monitors are connected. The overlay (Overlay.qml, the big board) is
// handed the same instance by the shell's panel loader as `service`.
// omarchy-tasks' own login flock stays as the second line of defense — it
// also covers a login run from a terminal.
Item {
  id: service
  visible: false

  // Injected by shell.qml when the service is mounted.
  property var shell: null

  // Bar-face state, from `count`: the stack depth (every open task — the
  // tasks are a stack, not a calendar). -1: not logged in.
  property int openCount: -1
  property bool reachable: true
  readonly property bool loggedOut: openCount === -1

  // Panel state, from `panel`: {date, stack: [], folders: [{name, tasks}]}.
  // null until a panel first opens.
  property var panelData: null
  property bool loading: false

  // How many panels are open across monitors.
  property int openPanels: 0

  // Pending action arguments; the Process commands bind to these (the gitea
  // runProc idiom — a Process command cannot take call arguments).
  property int doneSeq: 0
  property int doneVersion: 0
  property string addTitle: ""
  property string addTag: ""
  property int moveSeq: 0
  property int moveVersion: 0
  property string moveFolder: "-"

  // Folders that exist by intention only, so far: a folder is a tag, and a
  // tag with no open task has no row to drop onto. The overlay's "new
  // folder" names live here until a task lands in them (session-scoped —
  // the server never sees an empty folder, by design).
  property var extraFolders: []

  // The last refused write, as the server explained it ("Move refused: tag
  // "PCB" is invalid: …"). The board flashes it; the bar face ignores it.
  property string lastError: ""

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

  function addTask(title, tag) {
    title = String(title).trim()
    if (title === "" || addProc.running) return
    addTitle = title
    addTag = normalizeFolder(tag)
    addProc.running = true
  }

  // The server's tag rule (apps/tasks model.rs, valid_tag): lowercase
  // [a-z0-9-], first char alphanumeric, at most 32. It normalizes nothing
  // by design — "PCB" is refused, not lowercased — so the client does, in
  // this one place: every folder name, from any surface, passes through.
  function normalizeFolder(name) {
    var n = String(name === undefined || name === null ? "" : name).trim().toLowerCase()
    n = n.replace(/[\s_]+/g, "-").replace(/[^a-z0-9-]/g, "").replace(/^-+/, "").replace(/-+$/, "")
    return n.slice(0, 32)
  }

  // Refile under the version the face displayed; "" or "-" means the stack.
  function moveTask(seq, version, folder) {
    if (moveProc.running) return
    var f = folder === undefined || folder === null || String(folder).trim() === "-" ? "" : normalizeFolder(folder)
    moveSeq = seq
    moveVersion = version
    moveFolder = f === "" ? "-" : f
    moveProc.running = true
  }

  function ensureFolder(name) {
    name = normalizeFolder(name)
    if (name === "") return
    if (extraFolders.indexOf(name) !== -1) return
    var next = extraFolders.slice()
    next.push(name)
    extraFolders = next
  }

  // The overlay's model: the stack first, then every folder that holds a
  // task, then the intended-but-empty ones. Reads panelData and
  // extraFolders, so a binding on it re-evaluates when either changes.
  function folderList() {
    var out = [{ name: "", label: "Stack", tasks: panelData ? panelData.stack : [], pending: false }]
    var seen = {}
    if (panelData) {
      for (var i = 0; i < panelData.folders.length; i++) {
        var f = panelData.folders[i]
        seen[f.name] = true
        out.push({ name: f.name, label: f.name, tasks: f.tasks, pending: false })
      }
    }
    for (var j = 0; j < extraFolders.length; j++) {
      if (seen[extraFolders[j]]) continue
      out.push({ name: extraFolders[j], label: extraFolders[j], tasks: [], pending: true })
    }
    return out
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
    parts.push(openCount === 0 ? "stack empty" : openCount + " open")
    if (panelData && panelData.folders.length > 0)
      parts.push(panelData.folders.length + " folder" + (panelData.folders.length > 1 ? "s" : ""))
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
        service.openCount = isNaN(n) ? 0 : n
        loginPoll.stop()
      } else if (exitCode === 3) {
        service.openCount = -1
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
        service.openCount = -1
      } else {
        service.reachable = false
      }
    }
  }

  Process {
    id: loginProc
    command: ["omarchy-tasks", "login"]
  }

  function reportRefusal(what, text) {
    var msg = what + " refused: " + (String(text).trim() || "no reason given")
    console.warn("steveng.tasks: " + msg)
    lastError = ""
    lastError = msg
  }

  Process {
    id: doneProc
    command: ["omarchy-tasks", "done", String(service.doneSeq), String(service.doneVersion)]
    stderr: StdioCollector { id: doneErr }
    onExited: function(exitCode) {
      if (exitCode !== 0) service.reportRefusal("Done", doneErr.text)
      service.fetchPanel()
      service.refresh()
    }
  }

  Process {
    id: addProc
    command: service.addTag === ""
      ? ["omarchy-tasks", "add", service.addTitle]
      : ["omarchy-tasks", "add", "-t", service.addTag, service.addTitle]
    stderr: StdioCollector { id: addErr }
    onExited: function(exitCode) {
      if (exitCode !== 0) service.reportRefusal("Add", addErr.text)
      service.fetchPanel()
      service.refresh()
    }
  }

  Process {
    id: moveProc
    command: ["omarchy-tasks", "move", String(service.moveSeq), String(service.moveVersion), service.moveFolder]
    stderr: StdioCollector { id: moveErr }
    onExited: function(exitCode) {
      if (exitCode !== 0) service.reportRefusal("Move", moveErr.text)
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
