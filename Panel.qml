import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Filesystem usage in the bar.
//
// findmnt is the source rather than df: `findmnt --json --bytes` emits real
// JSON with byte counts already parsed, so nothing here has to guess where
// one whitespace-padded column ends and the next begins. Mount points with
// spaces in them are common on removable media named from a filesystem
// label, and column slicing gets those wrong.
//
// The one idea here that a plain readout does not have is the projection.
// A percentage tells you where you are; it does not tell you that something
// started writing four minutes ago and will fill the disk before dinner.
// Samples are kept in memory and fitted, and the line stays silent until the
// fit means something -- see trendFor().
Panel {
  id: root
  moduleName: "dbarke.disk"
  ipcTarget: "dbarke.disk"
  manageIpc: false

  // ---------------------------------------------------------------- theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool barVertical: bar ? bar.vertical : false

  // ------------------------------------------------------------- settings
  readonly property int intervalMs: Math.max(5, Number(setting("refreshIntervalSec", 30))) * 1000
  readonly property string barMount: String(setting("mount", "/"))
  readonly property string readout: String(setting("display", "percent"))
  readonly property int warnPercent: Number(setting("warnPercent", 85))
  readonly property bool warnOnAnyMount: setting("warnOnAnyMount", true) !== false
  readonly property real minSizeBytes: Math.max(0, Number(setting("minSizeGb", 1))) * 1073741824
  readonly property bool dedupe: setting("dedupe", true) !== false
  readonly property var excluded: parseList(setting("exclude", ""))

  // Pseudo and image-backed filesystems either report meaningless totals or
  // belong to something else (flatpak runtimes, container overlays, boot-time
  // ramdisks). --real drops most of them; these are the ones it keeps.
  readonly property var excludedTypes: ["squashfs", "overlay", "ramfs", "tmpfs",
    "devtmpfs", "fuse.portal", "fuse.gvfsd-fuse", "nsfs", "tracefs"]

  // ---------------------------------------------------------------- state
  property var mounts: []
  property bool ready: false
  property string lastError: ""
  property double lastPollMs: 0

  // target -> [[epochMs, usedBytes], ...], oldest first. In memory only: a
  // projection that survived a reboot would be describing a different
  // machine-state anyway, and the case this exists for -- something filling
  // the disk right now -- shows up within minutes of the shell starting.
  property var history: ({})
  // target -> { bytesPerMs, fullAtMs } for mounts that are measurably filling.
  property var trends: ({})

  // Countdowns re-read this rather than Date.now() so an open panel keeps
  // telling the truth between polls.
  property double nowMs: Date.now()

  readonly property var primary: pick(barMount)
  readonly property var fullest: mounts.length > 0 ? mounts[0] : null
  readonly property bool anyOver: {
    for (var i = 0; i < mounts.length; i++)
      if (over(mounts[i])) return true
    return false
  }
  readonly property bool alarming: over(primary) || (warnOnAnyMount && anyOver)

  // ------------------------------------------------------------- helpers
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function parseList(value) {
    if (Array.isArray(value)) return value
    var text = String(value || "").trim()
    if (text === "") return []
    try {
      var parsed = JSON.parse(text)
      return Array.isArray(parsed) ? parsed : []
    } catch (e) {
      return []
    }
  }

  function over(entry) {
    return !!entry && warnPercent > 0 && entry.percent >= warnPercent
  }

  function pick(target) {
    for (var i = 0; i < mounts.length; i++)
      if (mounts[i].target === target) return mounts[i]
    // Naming a mount that is not present should not blank the widget; the
    // fullest one is the honest answer to "how am I doing for space".
    return fullest
  }

  // Binary units, three significant figures, no trailing ".0" -- so a bar
  // label keeps its width as the number crosses 9.9G into 10G.
  function formatSize(bytes) {
    var value = Number(bytes)
    if (!isFinite(value) || value < 0) return "—"
    var units = ["B", "K", "M", "G", "T", "P"]
    var i = 0
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i++ }
    return value.toFixed(value >= 100 || i === 0 ? 0 : 1).replace(/\.0$/, "") + units[i]
  }

  function formatDuration(ms) {
    var minutes = Math.max(0, Math.round(ms / 60000))
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // A mount's short name. "/" reads better as "/" than as an empty string,
  // and a deep mount point is more recognisable by its last segment.
  function mountLabel(entry) {
    if (!entry) return ""
    var target = String(entry.target)
    if (target === "/") return "/"
    var parts = target.split("/").filter(function (p) { return p !== "" })
    return parts.length > 0 ? parts[parts.length - 1] : target
  }

  // -------------------------------------------------------------- reading
  function refreshNow() {
    if (!pollProc.running) pollProc.running = true
  }

  function applyOutput(text) {
    var raw = String(text || "").trim()
    if (raw === "") return

    var parsed
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      lastError = "findmnt returned something that is not JSON"
      return
    }

    var rows = (parsed && parsed.filesystems) || []
    var kept = []
    var seen = ({})

    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var target = String(row.target || "")
      var fstype = String(row.fstype || "")
      var size = Number(row.size || 0)
      var used = Number(row.used || 0)
      var avail = Number(row.avail || 0)

      if (target === "" || !(size > 0)) continue
      if (excludedTypes.indexOf(fstype) >= 0) continue
      if (excluded.indexOf(target) >= 0) continue
      if (size < minSizeBytes) continue

      // btrfs reports the subvolume in the source as /dev/x[/@home], so the
      // device alone is what says "these rows are one pool". Same device and
      // same total means the same space counted twice.
      var source = String(row.source || "")
      var device = source.replace(/\[.*\]$/, "")
      var key = device + ":" + size
      if (dedupe && seen[key]) continue
      if (dedupe) seen[key] = true

      kept.push({
        source: source,
        device: device,
        target: target,
        fstype: fstype,
        size: size,
        used: used,
        avail: avail,
        percent: size > 0 ? (used / size) * 100 : 0
      })
    }

    // Fullest first: the list is read top-down when the question is "what is
    // about to run out", and that ordering answers it without scanning.
    kept.sort(function (a, b) { return b.percent - a.percent })

    mounts = kept
    lastError = ""
    lastPollMs = Date.now()
    ready = true
    record(kept)
  }

  // ------------------------------------------------------------ projection
  //
  // Keep a bounded sample trail per mount and least-squares fit it. A
  // two-point slope would swing wildly every time a build wrote and then
  // cleaned a few hundred megabytes; the fit rides over that.

  readonly property int maxSamples: 240
  readonly property int minSpanMs: 300000      // 5 minutes
  readonly property int minSamples: 4
  readonly property real maxHorizonMs: 2592000000  // 30 days

  function record(entries) {
    var next = ({})
    var now = Date.now()

    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var trail = (history[entry.target] || []).slice()
      trail.push([now, entry.used])
      if (trail.length > maxSamples) trail = trail.slice(trail.length - maxSamples)
      next[entry.target] = trail
    }

    // Mounts that went away lose their trail with them: reusing samples from
    // before an unmount would fit a line across a gap that means nothing.
    history = next
    recompute()
  }

  function recompute() {
    var next = ({})
    for (var i = 0; i < mounts.length; i++) {
      var trend = fit(mounts[i])
      if (trend) next[mounts[i].target] = trend
    }
    trends = next
  }

  // Null unless the mount is measurably filling and would actually run out
  // inside the horizon. An empty trend line means "nothing to say", which is
  // the common case and should look like it.
  function fit(entry) {
    if (!entry) return null
    var trail = history[entry.target] || []
    if (trail.length < minSamples) return null

    var spanMs = trail[trail.length - 1][0] - trail[0][0]
    if (spanMs < minSpanMs) return null

    var n = trail.length
    var sumT = 0, sumU = 0, sumTT = 0, sumTU = 0
    var t0 = trail[0][0]
    for (var i = 0; i < n; i++) {
      var t = trail[i][0] - t0
      var u = trail[i][1]
      sumT += t; sumU += u; sumTT += t * t; sumTU += t * u
    }

    var denominator = n * sumTT - sumT * sumT
    if (!(denominator > 0)) return null

    var bytesPerMs = (n * sumTU - sumT * sumU) / denominator
    if (!(bytesPerMs > 0)) return null

    var msToFull = entry.avail / bytesPerMs
    if (!isFinite(msToFull) || msToFull <= 0 || msToFull > maxHorizonMs) return null

    return { bytesPerMs: bytesPerMs, fullAtMs: Date.now() + msToFull }
  }

  function trendFor(entry) {
    return entry ? (trends[entry.target] || null) : null
  }

  function trendText(entry) {
    var trend = trendFor(entry)
    if (!trend) return ""
    var remaining = trend.fullAtMs - nowMs
    if (remaining <= 0) return "Full"
    return "Filling · " + formatSize(trend.bytesPerMs * 3600000) + "/h · full in "
      + formatDuration(remaining)
  }

  // The closer the projected fill, the further the text travels from
  // foreground toward urgent. Mixed rather than hardcoded, so it respects
  // whatever theme is active -- there is no amber in the palette to reach for.
  function trendColor(entry) {
    if (over(entry)) return urgent
    var trend = trendFor(entry)
    if (!trend) return foreground
    var severity = 1 - clamp((trend.fullAtMs - nowMs) / maxHorizonMs, 0, 1)
    return Qt.tint(foreground, alpha(urgent, 0.25 + 0.6 * severity))
  }

  // ------------------------------------------------------------------ bar
  function barText(entry) {
    if (!entry) return "—"
    if (readout === "free") return formatSize(entry.avail)
    if (readout === "used") return formatSize(entry.used) + "/" + formatSize(entry.size)
    return Math.round(entry.percent) + "%"
  }

  function barColor(entry) {
    if (!entry) return dim
    if (over(entry)) return urgent
    // Another filesystem is the one in trouble. Say so with a tint rather
    // than full urgent: the number on the bar is not the problem, but you
    // should still open the panel.
    if (warnOnAnyMount && anyOver) return Qt.tint(foreground, alpha(urgent, 0.45))
    return trendColor(entry)
  }

  // Hover spells out what the single figure compresses.
  readonly property string barTooltip: {
    if (!ready) return "Measuring filesystems…"
    if (mounts.length === 0) return "No filesystems matched the filters"

    var lines = []
    for (var i = 0; i < mounts.length; i++) {
      var entry = mounts[i]
      var marker = entry === primary ? "▸ " : "  "
      var line = marker + entry.target + "  " + Math.round(entry.percent) + "% · "
        + formatSize(entry.avail) + " free of " + formatSize(entry.size)
      var trend = trendText(entry)
      if (trend !== "") line += "\n    " + trend
      lines.push(line)
    }
    return lines.join("\n")
  }

  // --------------------------------------------------------------- wiring
  Timer {
    interval: root.intervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  // Only drives the countdown inside a projection, so it can be lazy while
  // the panel is shut -- but it must not stop, because the bar carries the
  // projection's colour and a frozen tint would be a wrong tint.
  Timer {
    interval: root.opened ? 1000 : 30000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: pollProc
    running: false
    command: ["findmnt", "--json", "--list", "--bytes", "--real",
              "-o", "SOURCE,TARGET,FSTYPE,SIZE,USED,AVAIL"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "")
        console.warn("disk/findmnt", String(text).trim())
    }

    // findmnt exits 1 when nothing matched the filters, which is a legitimate
    // empty answer rather than a failure.
    onExited: function (exitCode) {
      if (exitCode !== 0 && exitCode !== 1)
        root.lastError = "findmnt exited " + exitCode
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    refreshNow()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  // The bar sizes a widget from its implicit size; without these the widget
  // loads cleanly, logs nothing, and occupies zero pixels.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Glyph plus one figure, coloured by the state of the filesystem it names.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    active: root.alarming
    horizontalMargin: 8.75
    tooltipText: root.barTooltip
    // A vertical bar has no room for the figure; it keeps the glyph and the
    // numbers stay in the panel.
    fixedWidth: root.barVertical ? -1 : barRow.implicitWidth + button.scaledHorizontalMargin * 2

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.refreshNow()
      else root.toggle()
    }

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(7)

      Text {
        textFormat: Text.PlainText
        // Nerd Font hard drive, and a warning triangle once something is
        // actually full. Written as an escape so the file survives any
        // editor or transport that mangles astral-plane characters.
        text: root.alarming ? "\uf071" : "\uf0a0"
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: !root.barVertical
        textFormat: Text.PlainText
        text: root.barText(root.primary)
        color: root.barColor(root.primary)
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) { if (t === "r" || t === "R") root.refreshNow() }
      onMoveRequested: function (dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelSectionHeader {
            width: parent.width
            text: "FILESYSTEMS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: !root.ready || root.mounts.length === 0 || root.lastError !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.lastError !== "" ? root.lastError
              : (!root.ready ? "Measuring…" : "No filesystems matched the filters.")
            color: root.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.mounts

            MountRow {
              required property var modelData
              width: column.width
              entry: modelData
            }
          }

          PanelSeparator {
            width: parent.width
            visible: root.ready && root.mounts.length > 0
          }

          Text {
            width: parent.width
            visible: root.ready
            textFormat: Text.PlainText
            text: {
              var age = Math.max(0, Math.round((root.nowMs - root.lastPollMs) / 1000))
              return "Updated " + (age < 5 ? "just now" : age + "s ago") + " · r to re-measure"
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // One filesystem: name and percentage, a meter, what that means in bytes,
  // and the projection when there is one.
  component MountRow: Column {
    id: mountRow
    property var entry: null

    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: Math.max(nameText.implicitHeight, percentText.implicitHeight)

      Text {
        id: nameText
        anchors.left: parent.left
        anchors.right: percentText.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        elide: Text.ElideMiddle
        text: mountRow.entry ? mountRow.entry.target : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        id: percentText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: mountRow.entry ? Math.round(mountRow.entry.percent) + "%" : ""
        color: root.trendColor(mountRow.entry)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Meter {
      width: parent.width
      value: mountRow.entry ? mountRow.entry.percent / 100 : 0
      alarming: root.over(mountRow.entry)
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: mountRow.entry
        ? root.formatSize(mountRow.entry.used) + " of " + root.formatSize(mountRow.entry.size)
          + " · " + root.formatSize(mountRow.entry.avail) + " free · " + mountRow.entry.fstype
        : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: text !== ""
      text: root.trendText(mountRow.entry)
      color: root.trendColor(mountRow.entry)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing how much of the filesystem is spoken for.
  component Meter: Item {
    id: meter
    property real value: 0
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }
}
