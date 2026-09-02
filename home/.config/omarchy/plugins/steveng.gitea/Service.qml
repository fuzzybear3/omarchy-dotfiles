import QtQuick
import Quickshell.Io

// The one-per-shell half of steveng.gitea (kind "service" — the media
// plugin's shape). The bar instantiates one BarWidget per monitor; they all
// bind to this single instance through bar.shell.serviceFor("steveng.gitea"),
// so the faces and panels cannot disagree, and the Gitea API is polled
// exactly once per tick no matter how many monitors are connected.
// omarchy-gitea's own flock stays as the second line of defense — it also
// covers a manual `check` in a terminal racing this service.
Item {
  id: service
  visible: false

  // Injected by shell.qml when the service is mounted.
  property var shell: null

  // Bar-face state, from `check`.
  property int running: 0
  property int failed: 0
  property var failedRepos: []
  property bool hasToken: true
  property bool reachable: true

  // Panel state, from `report`. null until a panel first opens.
  property var report: null
  property bool loading: false

  // Drill-down state, from `run`. detailRepo names the focused repo —
  // shared, so every monitor's panel shows the same drill-down.
  property var detail: null
  property string detailRepo: ""
  property bool detailLoading: false
  property bool focusPicked: false

  // How many panels are open across monitors; the panel-only work (the 1s
  // clock, the 10s in-flight refetch) runs while any of them is.
  property int openPanels: 0

  // Ticked once a second while a watched run is in flight, so elapsed
  // times count up without refetching.
  property real nowMs: Date.now()

  readonly property var detailRun: detail && detail.run ? detail.run : null
  readonly property bool detailInFlight: detailRun !== null && detailRun.status !== "completed"

  // One line at mount: seeing it once in the journal — with two monitors —
  // is the proof the service pattern took.
  Component.onCompleted: console.log("steveng.gitea: service mounted (single instance)")

  // ------------------------------------------------------------ lifecycle

  function panelOpened() {
    nowMs = Date.now()
    // Each opening re-picks the focus (made when the report lands); the
    // previous selection keeps rendering in the meantime.
    focusPicked = false
    if (detailRepo !== "") fetchDetail()
    fetchReport()
    refresh()
    openPanels++
  }

  function panelClosed() {
    openPanels = Math.max(0, openPanels - 1)
  }

  // ------------------------------------------------------------- fetching

  function refresh() {
    if (!checkProc.running) checkProc.running = true
  }

  function fetchReport() {
    loading = true
    if (!reportProc.running) reportProc.running = true
  }

  function fetchDetail() {
    if (detailRepo === "") return
    detailLoading = true
    if (!runProc.running) runProc.running = true
  }

  // ------------------------------------------------------ repo selection

  function repoIndex() {
    if (!report) return -1
    for (var i = 0; i < report.repos.length; i++)
      if (report.repos[i].repo === detailRepo) return i
    return -1
  }

  function currentRepoEntry() {
    var i = repoIndex()
    return i >= 0 ? report.repos[i] : null
  }

  function switchRepo(delta) {
    if (!report || report.repos.length === 0) return
    var i = repoIndex()
    i = i < 0 ? 0 : (i + delta + report.repos.length) % report.repos.length
    if (report.repos[i].repo === detailRepo) return
    detailRepo = report.repos[i].repo
    detail = null
    fetchDetail()
  }

  // ------------------------------------------- shared data/format helpers

  function repoSide(repoEntry) {
    if (repoEntry.running > 0) return repoEntry.running + " in flight"
    if (!repoEntry.latest) return "no runs"
    return "#" + repoEntry.latest.run_number + "  " + repoEntry.latest.workflow
  }

  function relTime(iso) {
    if (!iso) return "—"
    var m = Math.floor((Date.now() - Date.parse(iso)) / 60000)
    if (!isFinite(m) || m < 0) return "—"
    if (m < 1) return "now"
    if (m < 60) return m + "m ago"
    var h = Math.floor(m / 60)
    if (h < 24) return h + "h ago"
    return Math.floor(h / 24) + "d ago"
  }

  function repoBase(full) {
    var i = String(full).indexOf("/")
    return i >= 0 ? String(full).slice(i + 1) : String(full)
  }

  // Gitea's zero times come back as the epoch (and the API has been seen
  // returning year-1 too); both mean "hasn't happened yet".
  function isZeroTime(iso) {
    return !iso || String(iso).indexOf("1970-") === 0 || String(iso).indexOf("0001-") === 0
  }

  function fmtDur(s) {
    if (!isFinite(s) || s < 0) return ""
    if (s < 60) return s + "s"
    var m = Math.floor(s / 60)
    s = s % 60
    if (m < 60) return m + "m" + (s < 10 ? "0" : "") + s + "s"
    var h = Math.floor(m / 60)
    return h + "h" + ((m % 60) < 10 ? "0" : "") + (m % 60) + "m"
  }

  // Duration between two timestamps; an unset end means "still going",
  // timed against the ticking clock.
  function durBetween(startIso, endIso) {
    if (isZeroTime(startIso)) return ""
    var end = isZeroTime(endIso) ? nowMs : Date.parse(endIso)
    return fmtDur(Math.max(0, Math.round((end - Date.parse(startIso)) / 1000)))
  }

  function jobStepsDone(job) {
    var n = 0
    for (var i = 0; i < job.steps.length; i++)
      if (job.steps[i].status === "completed") n++
    return n
  }

  function jobSide(job) {
    var dur = durBetween(job.started_at, job.completed_at)
    // A queued job reports no steps yet; "0/0" would just be noise.
    if (job.steps.length === 0) return dur !== "" ? dur : "queued"
    return jobStepsDone(job) + "/" + job.steps.length + (dur !== "" ? " · " + dur : " · queued")
  }

  function stepGlyph(step) {
    if (step.conclusion === "failure") return "✗"
    if (step.conclusion === "success") return "✓"
    if (step.conclusion === "skipped" || step.conclusion === "cancelled") return "○"
    if (step.status === "in_progress") return "→"
    return "·"
  }

  function runMetaText() {
    if (!detailRun) return ""
    // A PR run's head_branch comes back null — skip what isn't there.
    var parts = ["#" + detailRun.run_number, detailRun.workflow]
    if (detailRun.branch) parts.push(detailRun.branch)
    if (detailRun.event) parts.push(detailRun.event)
    return parts.join(" · ")
  }

  function runStateText() {
    if (!detailRun) return ""
    if (detailRun.status !== "completed") {
      var dur = durBetween(detailRun.started_at, null)
      return dur !== "" ? dur : "queued"
    }
    return detailRun.conclusion + " · " + durBetween(detailRun.started_at, detailRun.completed_at)
  }

  function heroMeta() {
    if (!hasToken) return "No token — expected at ~/.config/gitea-mcp/token"
    if (!reachable) return "Unreachable — last known state"
    var parts = []
    if (report) parts.push(report.repos.length + " repos")
    parts.push(failed > 0 ? failed + " failing" : "all green")
    if (running > 0) parts.push(running + " in flight")
    if (loading) parts.push("refreshing…")
    return parts.join(" · ")
  }

  // ------------------------------------------------------------ processes

  Process {
    id: checkProc
    command: ["omarchy-gitea", "check"]
    stdout: StdioCollector { id: checkOut }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        try {
          const s = JSON.parse(checkOut.text)
          service.running = s.running
          service.failed = s.failed
          service.failedRepos = s.failedRepos
          service.hasToken = true
          service.reachable = true
        } catch (e) {
          service.reachable = false
        }
      } else if (exitCode === 3) {
        service.hasToken = false
      } else {
        // Token exists but the server is unreachable (off the shop LAN, or
        // Gitea is down): keep the last counts, dimmed by the widgets.
        service.reachable = false
      }
    }
  }

  Process {
    id: reportProc
    command: ["omarchy-gitea", "report"]
    stdout: StdioCollector { id: reportOut }
    onExited: function(exitCode) {
      service.loading = false
      if (exitCode === 0) {
        try {
          service.report = JSON.parse(reportOut.text)
          service.reachable = true
        } catch (e) {
          service.reachable = false
          return
        }
        if (!service.focusPicked) {
          service.focusPicked = true
          var rs = service.report.repos
          var pick = ""
          for (var i = 0; i < rs.length && pick === ""; i++)
            if (rs[i].running > 0) pick = rs[i].repo
          for (i = 0; i < rs.length && pick === ""; i++)
            if (rs[i].latest && rs[i].latest.conclusion === "failure") pick = rs[i].repo
          // Quiet everywhere: focus the configured primary (the monorepo),
          // else whatever sorts first.
          if (pick === "" && service.report.primary !== "")
            for (i = 0; i < rs.length && pick === ""; i++)
              if (rs[i].repo === service.report.primary) pick = rs[i].repo
          if (pick === "" && rs.length > 0) pick = rs[0].repo
          if (pick !== "" && pick !== service.detailRepo) {
            service.detailRepo = pick
            service.detail = null
          }
          service.fetchDetail()
        }
      } else if (exitCode === 3) {
        service.hasToken = false
      } else {
        service.reachable = false
      }
    }
  }

  Process {
    id: runProc
    command: ["omarchy-gitea", "run", service.detailRepo]
    stdout: StdioCollector { id: runOut }
    onExited: function(exitCode) {
      service.detailLoading = false
      if (exitCode !== 0) return
      try {
        const d = JSON.parse(runOut.text)
        if (d.repo === service.detailRepo) service.detail = d
        // The focus switched repos while this fetch ran; go again.
        else if (service.detailRepo !== "") service.fetchDetail()
      } catch (e) {}
    }
  }

  // --------------------------------------------------------------- timers

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: service.refresh()
  }

  // Runs seen in flight usually finish within a minute or two; while any
  // are showing, poll faster so the glyph doesn't outlive the run.
  Timer {
    interval: 15000
    running: service.running > 0 && service.reachable
    repeat: true
    onTriggered: service.refresh()
  }

  // The watched run's clock: tick elapsed locally every second…
  Timer {
    interval: 1000
    running: service.openPanels > 0 && service.detailInFlight
    repeat: true
    onTriggered: service.nowMs = Date.now()
  }

  // …and refetch its jobs and steps every ten.
  Timer {
    interval: 10000
    running: service.openPanels > 0 && service.detailInFlight
    repeat: true
    onTriggered: {
      service.fetchDetail()
      service.refresh()
    }
  }
}
