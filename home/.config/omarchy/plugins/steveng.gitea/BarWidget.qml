import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

// The shop Gitea's bar presence: Actions runs in flight, and repos whose
// latest completed run failed, polled through `omarchy-gitea check`. The
// script raises the failure/merge notifications as a side effect of the same
// poll, so the bar being alive is what keeps the tracker tracking.
//
// The bar face stays quiet: all green and nothing running → a bare git-branch
// glyph (the panel must stay reachable for watching runs and merges, so the
// widget never hides); a failure shows an x-circle with the repo count, runs
// in flight a refresh glyph with theirs; no token or unreachable dims the
// glyph. Clicking opens an
// anchored panel (the system-monitor's design dialect — hero, stat tiles,
// sectioned rows) fed by `omarchy-gitea report`, fetched fresh on each open.
//
// The panel shows ONE repo at a time — a pager (‹ ›, or ← → on the
// keyboard) switches — which buys the space for the whole current run
// (`omarchy-gitea run R`): every job with its full step list and per-step
// durations ticking live, plus the repo's recent-runs history. The in-flight
// (else failing, else primary) repo is focused on open, and the detail
// refetches every 10s while the run is going — the point is to watch a run
// without opening the web UI's Actions tab.
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — the japanquake plugin's convention.)
Ui.Panel {
  id: root
  moduleName: "steveng.gitea"
  ipcTarget: "steveng.gitea"

  // Bar-face state, from `check`.
  property int running: 0
  property int failed: 0
  property var failedRepos: []
  property bool hasToken: true
  property bool reachable: true

  // Panel state, from `report`. null until the first open.
  property var report: null
  property bool loading: false

  // Drill-down state, from `run`. detailRepo names the expanded repo row.
  property var detail: null
  property string detailRepo: ""
  property bool detailLoading: false
  property bool autoExpanded: false
  // Ticked once a second while a watched run is in flight, so elapsed times
  // count up without refetching.
  property real nowMs: Date.now()

  readonly property var detailRun: detail && detail.run ? detail.run : null
  readonly property bool detailInFlight: detailRun !== null && detailRun.status !== "completed"

  // The system-monitor panel's color recipe, so side-by-side panels match.
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color muted: Qt.darker(foreground, 1.4)
  readonly property color trackColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  // No warning role exists in the palette — blend one (the system-monitor's
  // recipe) rather than hardcoding an orange that clashes on half the themes.
  readonly property color warningColor: Qt.tint(accent, Qt.rgba(urgent.r, urgent.g, urgent.b, 0.6))
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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

  function openWeb(path) {
    var base = report && report.url ? report.url : ""
    if (base === "" || !bar) return
    bar.run("xdg-open " + base + path)
    close()
  }

  function conclusionColor(repoEntry) {
    if (!repoEntry) return muted
    if (repoEntry.running > 0) return warningColor
    if (!repoEntry.latest) return muted
    if (repoEntry.latest.conclusion === "failure") return urgent
    if (repoEntry.latest.conclusion === "success") return accent
    return muted
  }

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

  // Duration between two timestamps; an unset end means "still going", timed
  // against the ticking clock.
  function durBetween(startIso, endIso) {
    if (isZeroTime(startIso)) return ""
    var end = isZeroTime(endIso) ? nowMs : Date.parse(endIso)
    return fmtDur(Math.max(0, Math.round((end - Date.parse(startIso)) / 1000)))
  }

  function jobDotColor(job) {
    if (job.conclusion === "failure") return urgent
    if (job.conclusion === "success") return accent
    if (job.status !== "completed") return warningColor
    return muted
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

  function stepColor(step) {
    if (step.conclusion === "failure") return urgent
    if (step.conclusion === "success") return accent
    if (step.status === "in_progress") return warningColor
    return muted
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

  onOpenedChanged: {
    if (opened) {
      nowMs = Date.now()
      // Each open starts with a fresh focus pick (made when the report
      // lands); the previous selection keeps rendering in the meantime.
      autoExpanded = false
      if (detailRepo !== "") fetchDetail()
      fetchReport()
      refresh()
    }
  }

  Process {
    id: checkProc
    command: ["omarchy-gitea", "check"]
    stdout: StdioCollector { id: checkOut }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        try {
          const s = JSON.parse(checkOut.text)
          root.running = s.running
          root.failed = s.failed
          root.failedRepos = s.failedRepos
          root.hasToken = true
          root.reachable = true
        } catch (e) {
          root.reachable = false
        }
      } else if (exitCode === 3) {
        root.hasToken = false
      } else {
        // Token exists but the server is unreachable (off the shop LAN, or
        // Gitea is down): keep the last counts, dimmed.
        root.reachable = false
      }
    }
  }

  Process {
    id: reportProc
    command: ["omarchy-gitea", "report"]
    stdout: StdioCollector { id: reportOut }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode === 0) {
        try {
          root.report = JSON.parse(reportOut.text)
          root.reachable = true
        } catch (e) {
          root.reachable = false
          return
        }
        if (root.opened && !root.autoExpanded) {
          root.autoExpanded = true
          var rs = root.report.repos
          var pick = ""
          for (var i = 0; i < rs.length && pick === ""; i++)
            if (rs[i].running > 0) pick = rs[i].repo
          for (i = 0; i < rs.length && pick === ""; i++)
            if (rs[i].latest && rs[i].latest.conclusion === "failure") pick = rs[i].repo
          // Quiet everywhere: focus the configured primary (the monorepo),
          // else whatever sorts first.
          if (pick === "" && root.report.primary !== "")
            for (i = 0; i < rs.length && pick === ""; i++)
              if (rs[i].repo === root.report.primary) pick = rs[i].repo
          if (pick === "" && rs.length > 0) pick = rs[0].repo
          if (pick !== "" && pick !== root.detailRepo) {
            root.detailRepo = pick
            root.detail = null
          }
          root.fetchDetail()
        }
      } else if (exitCode === 3) {
        root.hasToken = false
      } else {
        root.reachable = false
      }
    }
  }

  Process {
    id: runProc
    command: ["omarchy-gitea", "run", root.detailRepo]
    stdout: StdioCollector { id: runOut }
    onExited: function(exitCode) {
      root.detailLoading = false
      if (exitCode !== 0) return
      try {
        const d = JSON.parse(runOut.text)
        if (d.repo === root.detailRepo) root.detail = d
        // The expansion switched repos while this fetch ran; go again.
        else if (root.detailRepo !== "") root.fetchDetail()
      } catch (e) {}
    }
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Runs seen in flight usually finish within a minute or two; while any are
  // showing, poll faster so the glyph doesn't outlive the run.
  Timer {
    interval: 15000
    running: root.running > 0 && root.reachable
    repeat: true
    onTriggered: root.refresh()
  }

  // The watched run's clock: tick elapsed locally every second…
  Timer {
    interval: 1000
    running: root.opened && root.detailInFlight
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // …and refetch its jobs and steps every ten.
  Timer {
    interval: 10000
    running: root.opened && root.detailInFlight
    repeat: true
    onTriggered: {
      root.fetchDetail()
      root.refresh()
    }
  }

  Ui.WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    opacity: (!root.hasToken || !root.reachable) ? 0.45 : 1.0
    active: root.failed > 0
    activeColor: root.urgent
    // \uf057 x-circle (failed repos), \uf021 refresh arrows (in flight),
    // \uf418 git branch (token and reachability states). Escapes, not literal
    // glyphs: a literal PUA character has already been eaten once by an
    // edit-tool round trip.
    text: {
      if (!root.hasToken) return "\uf418"
      if (!root.reachable) return "\uf418 –"
      let parts = []
      if (root.failed > 0) parts.push("\uf057 " + root.failed)
      if (root.running > 0) parts.push("\uf021 " + root.running)
      return parts.length > 0 ? parts.join("  ") : "\uf418"
    }
    tooltipText: {
      if (!root.hasToken) return "Gitea — no token (expected at ~/.config/gitea-mcp/token)"
      if (!root.reachable) return "Gitea unreachable — showing the last known state"
      let lines = []
      if (root.failed > 0) lines.push("Failing: " + root.failedRepos.join(", "))
      if (root.running > 0) lines.push(root.running + " Actions run(s) in flight")
      if (lines.length === 0) lines.push("Gitea — all green")
      lines.push("Click for the tracker panel")
      return lines.join("\n")
    }
    onPressed: root.toggle()
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(640))

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.fetchReport()
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.switchRepo(dx)
        } else if (dy !== 0 && scrollArea.scrollable) {
          var max = Math.max(0, scrollArea.contentHeight - scrollArea.height)
          scrollArea.contentY = Math.max(0, Math.min(max, scrollArea.contentY + dy * Style.space(60)))
        }
      }
      onTextKey: function(text) {
        if (text === "r" || text === "R") {
          root.fetchReport()
          root.fetchDetail()
        } else if (text === "o" || text === "O") {
          root.openWeb("")
        }
      }

      // A Flickable, not a ScrollView: the stock overlay scrollbar paints a
      // wide dark track ON TOP of the content's right column. Here the
      // content cedes a gutter whenever scrolling is possible, and the bar
      // itself is a slim theme-tinted handle with no track.
      Flickable {
        id: scrollArea
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        readonly property bool scrollable: contentHeight > height

        ScrollBar.vertical: ScrollBar {
          id: vbar
          policy: scrollArea.scrollable ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
          background: Item {}
          contentItem: Rectangle {
            implicitWidth: Style.space(3)
            radius: width / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
              vbar.pressed ? 0.5 : 0.25)
          }
        }

        Column {
          id: panelColumn
          width: scrollArea.width - (scrollArea.scrollable ? Style.space(10) : 0)
          spacing: Style.space(9)

          Ui.PanelHero {
            width: parent.width
            title: "Gitea"
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: "\uf418"
                color: root.failed > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(4)
                Ui.PanelActionButton {
                  iconText: "\uf021"
                  tooltipText: "Refresh (R)"
                  foreground: root.foreground
                  hoverColor: root.accent
                  fontFamily: root.fontFamily
                  onClicked: {
                    root.fetchReport()
                    root.fetchDetail()
                  }
                }
                Ui.PanelActionButton {
                  iconText: "\uf08e"
                  tooltipText: "Open Gitea (O)"
                  foreground: root.foreground
                  hoverColor: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.openWeb("")
                }
              }
            }
          }

          Ui.PanelSeparator { foreground: root.foreground }

          // ---------- Headline tiles ----------
          Row {
            width: parent.width
            spacing: Style.space(8)

            StatTile {
              width: (parent.width - parent.spacing * 2) / 3
              title: "FAILING"
              value: String(root.failed)
              detail: root.failed > 0 ? root.failedRepos.map(root.repoBase).join(", ") : "all green"
              alarming: root.failed > 0
              meter: root.report && root.report.repos.length > 0
                ? (root.failed > 0 ? root.failed * 100 / root.report.repos.length : 100)
                : -1
              meterColor: root.failed > 0 ? root.urgent : root.accent
            }

            StatTile {
              width: (parent.width - parent.spacing * 2) / 3
              title: "IN FLIGHT"
              value: String(root.running)
              detail: root.running > 0 ? "Actions running" : "idle"
              meter: root.report && root.report.repos.length > 0 && root.running > 0
                ? Math.min(100, root.running * 100 / root.report.repos.length)
                : -1
              meterColor: root.warningColor
            }

            StatTile {
              width: (parent.width - parent.spacing * 2) / 3
              title: "LAST MERGE"
              value: root.report && root.report.merges.length > 0
                ? root.relTime(root.report.merges[0].merged_at)
                : "—"
              detail: root.report && root.report.merges.length > 0
                ? root.repoBase(root.report.merges[0].repo) + " #" + root.report.merges[0].number
                : "none seen"
              meter: -1
            }
          }

          Ui.PanelSeparator { foreground: root.foreground }

          // ---------- One repo at a time: the pager and its current run ----
          Column {
            width: parent.width
            spacing: Style.space(5)
            visible: root.report !== null

            SectionHeading {
              title: "REPO"
              value: root.report && root.report.repos.length > 0 && root.repoIndex() >= 0
                ? (root.repoIndex() + 1) + " of " + root.report.repos.length
                : ""
            }

            Item {
              width: parent.width
              implicitHeight: Style.space(24)

              Ui.PanelActionButton {
                id: prevBtn
                iconText: "‹"
                tooltipText: "Previous repo (←)"
                foreground: root.foreground
                hoverColor: root.accent
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.switchRepo(-1)
              }

              Rectangle {
                id: pagerDot
                width: Style.space(6)
                height: width
                radius: width / 2
                color: root.conclusionColor(root.currentRepoEntry())
                anchors.left: prevBtn.right
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: root.detailRepo
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
                anchors.left: pagerDot.right
                anchors.leftMargin: Style.space(6)
                anchors.right: pagerSide.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: pagerSide
                text: root.currentRepoEntry() ? root.repoSide(root.currentRepoEntry()) : ""
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: nextBtn.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }

              Ui.PanelActionButton {
                id: nextBtn
                iconText: "›"
                tooltipText: "Next repo (→)"
                foreground: root.foreground
                hoverColor: root.accent
                fontFamily: root.fontFamily
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.switchRepo(1)
              }
            }

            DetailCard { width: parent.width }

            // The selected repo's run history, newest first.
            Column {
              width: parent.width
              spacing: Style.space(3)
              visible: root.detail !== null && root.detail.recent !== undefined
                && root.detail.recent.length > 0

              SectionHeading {
                title: "RECENT RUNS"
                value: "click to open"
              }

              Repeater {
                model: root.detail && root.detail.recent ? root.detail.recent : []

                ListRow {
                  required property var modelData
                  dotColor: modelData.conclusion === "failure" ? root.urgent
                    : modelData.conclusion === "success" ? root.accent : root.muted
                  mainText: "#" + modelData.run_number + "  " + modelData.workflow
                  sideText: root.durBetween(modelData.started_at, modelData.completed_at)
                    + " · " + root.relTime(modelData.started_at)
                  tipText: modelData.title
                  link: "/" + root.detail.repo + "/actions/runs/" + modelData.id
                }
              }
            }
          }

          Ui.PanelSeparator { foreground: root.foreground; visible: root.report !== null }

          // ---------- Recent merges ----------
          Column {
            width: parent.width
            spacing: Style.space(3)
            visible: root.report !== null && root.report.merges.length > 0

            SectionHeading {
              title: "RECENT MERGES"
              value: root.report ? String(root.report.merges.length) : ""
            }

            Repeater {
              model: root.report ? root.report.merges : []

              ListRow {
                required property var modelData
                showDot: false
                mainText: root.repoBase(modelData.repo) + " #" + modelData.number + "  " + modelData.title
                sideText: root.relTime(modelData.merged_at)
                tipText: modelData.title
                link: "/" + modelData.repo + "/pulls/" + modelData.number
              }
            }
          }

          Text {
            width: parent.width
            visible: root.report === null
            text: root.loading ? "Fetching from Gitea…"
              : root.hasToken ? "Gitea is unreachable" : "No token"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }
    }
  }

  // ---------- Local components, in the system-monitor panel's dialect ------

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
      elide: Text.ElideRight
      width: Math.min(implicitWidth, parent.width * 0.62)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
    }
  }

  component Meter: Rectangle {
    id: meterItem
    property real value: -1
    property color fillColor: root.accent

    visible: value >= 0
    height: Style.space(3)
    radius: height / 2
    color: root.trackColor

    Rectangle {
      width: meterItem.width * Math.max(0, Math.min(1, meterItem.value / 100))
      height: meterItem.height
      radius: meterItem.radius
      color: meterItem.fillColor

      Behavior on width {
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
      }
    }
  }

  component StatTile: Ui.BorderSurface {
    id: tile
    property string title: ""
    property string value: "—"
    property string detail: ""
    property real meter: -1
    property color meterColor: root.accent
    property bool alarming: false

    height: Style.space(78)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.foreground, root.accent)
    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(9)
      spacing: Style.space(2)

      Text {
        text: tile.title
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
      }

      Text {
        text: tile.value
        color: tile.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        width: parent.width
        text: tile.detail
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Meter {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(9)
      value: tile.meter
      fillColor: tile.meterColor
    }
  }

  component ListRow: Rectangle {
    id: row
    property color dotColor: root.muted
    property bool showDot: true
    property bool expanded: false
    property string mainText: ""
    property string sideText: ""
    property string tipText: ""
    property string link: ""

    signal activated()

    width: parent ? parent.width : 0
    height: Style.space(24)
    radius: Style.cornerRadius
    color: (expanded || rowMouse.containsMouse) ? root.trackColor : "transparent"

    Rectangle {
      id: dot
      visible: row.showDot
      width: Style.space(6)
      height: width
      radius: width / 2
      color: row.dotColor
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: row.mainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: row.showDot ? Style.space(18) : Style.space(6)
      anchors.right: sideLabel.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: sideLabel
      text: row.sideText
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (row.link !== "") root.openWeb(row.link)
        else row.activated()
      }
    }

    Ui.PanelToolTip {
      visible: rowMouse.containsMouse && row.tipText !== ""
      text: row.tipText
      fontFamily: root.fontFamily
    }
  }

  // The expanded run: title + link, meta and state, then a row per job with
  // step progress, and the step that matters (executing or failed) beneath.
  component DetailCard: Ui.BorderSurface {
    id: card
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.foreground, root.accent)
    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
    implicitHeight: cardColumn.implicitHeight + Style.space(18)

    Column {
      id: cardColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(9)
      spacing: Style.space(5)

      Text {
        width: parent.width
        visible: root.detailRun === null
        text: root.detailLoading ? "Fetching run…" : "No runs yet"
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item {
        width: parent.width
        visible: root.detailRun !== null
        implicitHeight: Math.max(runTitle.implicitHeight, openRun.implicitHeight)

        Text {
          id: runTitle
          text: root.detailRun ? root.detailRun.title : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          anchors.left: parent.left
          anchors.right: openRun.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
        }

        Ui.PanelActionButton {
          id: openRun
          iconText: "\uf08e"
          tooltipText: "Open this run"
          foreground: root.foreground
          hoverColor: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.openWeb("/" + root.detail.repo + "/actions/runs/" + root.detailRun.id)
        }
      }

      Item {
        width: parent.width
        visible: root.detailRun !== null
        implicitHeight: runMeta.implicitHeight

        Text {
          id: runMeta
          text: root.runMetaText()
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          anchors.left: parent.left
          anchors.right: runState.left
          anchors.rightMargin: Style.space(8)
        }

        Text {
          id: runState
          text: root.runStateText()
          color: root.detailInFlight ? root.warningColor
            : (root.detailRun && root.detailRun.conclusion === "failure") ? root.urgent
            : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.right: parent.right
        }
      }

      Repeater {
        model: root.detail ? root.detail.jobs : []

        Column {
          id: jobItem
          required property var modelData
          width: parent ? parent.width : 0
          spacing: Style.space(1)

          Item {
            width: parent.width
            implicitHeight: Style.space(18)

            Rectangle {
              width: Style.space(6)
              height: width
              radius: width / 2
              color: root.jobDotColor(jobItem.modelData)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: jobItem.modelData.name
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.right: jobSide.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: jobSide
              text: root.jobSide(jobItem.modelData)
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // The full step list — the single-repo view's reason to exist. The
          // executing step's duration ticks with the shared clock.
          Repeater {
            model: jobItem.modelData.steps

            Item {
              id: stepItem
              required property var modelData
              width: parent ? parent.width : 0
              implicitHeight: Style.space(15)

              Text {
                text: root.stepGlyph(stepItem.modelData)
                color: root.stepColor(stepItem.modelData)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: stepItem.modelData.name
                color: stepItem.modelData.conclusion === "failure" ? root.urgent
                  : stepItem.modelData.status === "in_progress" ? root.foreground
                  : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                anchors.left: parent.left
                anchors.leftMargin: Style.space(24)
                anchors.right: stepDur.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: stepDur
                text: root.durBetween(stepItem.modelData.started_at,
                  stepItem.modelData.status === "completed" ? stepItem.modelData.completed_at : null)
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }
      }
    }
  }
}
