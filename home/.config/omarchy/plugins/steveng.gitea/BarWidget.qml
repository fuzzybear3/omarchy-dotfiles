import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui as Ui

// The per-monitor half of steveng.gitea: a thin view over the plugin's
// service instance (Service.qml, mounted once by the shell regardless of
// monitor count) reached through bar.shell.serviceFor. All polling, timers,
// and state live in the service; this file only renders and forwards input,
// so N monitors mean N faces of the same tracker, never N trackers.
//
// The bar face stays quiet: all green and nothing running → a bare
// git-branch glyph (the panel must stay reachable for watching runs and
// merges, so the widget never hides); a failure shows an x-circle with the
// repo count, runs in flight a refresh glyph with theirs; no token or
// unreachable dims the glyph. Clicking opens an anchored panel (the
// system-monitor's design dialect) showing ONE repo at a time — pager
// arrows or ← → switch — with the current run's jobs, full step lists,
// live-ticking durations, and the repo's recent runs.
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — the japanquake plugin's convention.)
Ui.Panel {
  id: root
  moduleName: "steveng.gitea"
  ipcTarget: "steveng.gitea"

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("steveng.gitea") : null

  // Null-safe proxies: the service mounts at shell startup, but bindings
  // evaluate before it lands, and a broken mount must degrade to a dimmed
  // glyph rather than a wall of TypeErrors.
  readonly property int running: svc ? svc.running : 0
  readonly property int failed: svc ? svc.failed : 0
  readonly property var failedRepos: svc ? svc.failedRepos : []
  readonly property bool hasToken: svc ? svc.hasToken : true
  readonly property bool reachable: svc ? svc.reachable : false
  readonly property var report: svc ? svc.report : null
  readonly property bool loading: svc ? svc.loading : false
  readonly property var detail: svc ? svc.detail : null
  readonly property string detailRepo: svc ? svc.detailRepo : ""
  readonly property bool detailLoading: svc ? svc.detailLoading : false
  readonly property var detailRun: svc ? svc.detailRun : null
  readonly property bool detailInFlight: svc ? svc.detailInFlight : false

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

  // Forwarders to the service; data/format helpers live there so every
  // monitor's face agrees, color helpers stay here with the palette.
  function fetchReport() { if (svc) svc.fetchReport() }
  function fetchDetail() { if (svc) svc.fetchDetail() }
  function switchRepo(delta) { if (svc) svc.switchRepo(delta) }
  function repoIndex() { return svc ? svc.repoIndex() : -1 }
  function currentRepoEntry() { return svc ? svc.currentRepoEntry() : null }
  function repoSide(e) { return svc ? svc.repoSide(e) : "" }
  function relTime(iso) { return svc ? svc.relTime(iso) : "" }
  function repoBase(full) { return svc ? svc.repoBase(full) : String(full) }
  function durBetween(a, b) { return svc ? svc.durBetween(a, b) : "" }
  function jobSide(job) { return svc ? svc.jobSide(job) : "" }
  function stepGlyph(step) { return svc ? svc.stepGlyph(step) : "" }
  function runMetaText() { return svc ? svc.runMetaText() : "" }
  function runStateText() { return svc ? svc.runStateText() : "" }
  function heroMeta() { return svc ? svc.heroMeta() : "Service not mounted" }

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

  function jobDotColor(job) {
    if (job.conclusion === "failure") return urgent
    if (job.conclusion === "success") return accent
    if (job.status !== "completed") return warningColor
    return muted
  }

  function stepColor(step) {
    if (step.conclusion === "failure") return urgent
    if (step.conclusion === "success") return accent
    if (step.status === "in_progress") return warningColor
    return muted
  }

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
    opacity: (!root.hasToken || !root.reachable) ? 0.45 : 1.0
    active: root.failed > 0
    activeColor: root.urgent
    // \uf057 x-circle (failed repos), \uf021 refresh arrows (in flight),
    // \uf418 git branch (quiet, token, and reachability states). Escapes,
    // not literal glyphs: a literal PUA character has already been eaten
    // once by an edit-tool round trip.
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
              : !root.svc ? "Tracker service not mounted"
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
    property string mainText: ""
    property string sideText: ""
    property string tipText: ""
    property string link: ""

    width: parent ? parent.width : 0
    height: Style.space(24)
    radius: Style.cornerRadius
    color: rowMouse.containsMouse ? root.trackColor : "transparent"

    Rectangle {
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
      onClicked: if (row.link !== "") root.openWeb(row.link)
    }

    Ui.PanelToolTip {
      visible: rowMouse.containsMouse && row.tipText !== ""
      text: row.tipText
      fontFamily: root.fontFamily
    }
  }

  // The focused run: title + link, meta and state, then a row per job with
  // step progress and the full step list beneath — the executing step's
  // duration ticks with the service's shared clock.
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
              anchors.right: jobSideLabel.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: jobSideLabel
              text: root.jobSide(jobItem.modelData)
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // The full step list — the single-repo view's reason to exist.
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
