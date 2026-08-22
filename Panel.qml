import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "kairos.flight-tracker"
  ipcTarget: "kairos.flight-tracker"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property bool openedFromHotkey: false
  property bool settingsOpen: false

  property var aircraft: []
  property bool loading: false
  property bool hasError: false
  property string errorText: ""

  property bool locationReady: false
  property real latitude: 0
  property real longitude: 0
  property string locationLabel: "Location unavailable"
  property string cityInput: ""
  property var cityResults: []
  property bool searchingCity: false
  property bool manualOverride: false

  property real lastUpdatedMs: 0
  property real statusClockMs: Date.now()

  // Byte ceilings for each network response, sized from measured replies so a
  // legitimate one is never truncated. At the 250 nm maximum radius adsb.fi
  // returned 299 KiB over New York, 247 KiB over Chicago, 246 KiB over Los
  // Angeles, 111 KiB over London; 1 MiB leaves better than 3x headroom over
  // the busiest of those and is still a hard bound on what the shell holds.
  // ipwho.is returned 963 bytes and Nominatim 3.0 KiB at limit=5.
  readonly property int locationCapBytes: 65536
  readonly property int flightsCapBytes: 1048576
  readonly property int citySearchCapBytes: 65536

  readonly property int refreshIntervalSec: Math.max(30, parseInt(setting("refreshIntervalSec", 30), 10) || 30)
  readonly property int radiusNm: Math.min(250, Math.max(1, parseInt(setting("radiusNm", 25), 10) || 25))
  readonly property string displayMode: setting("displayMode", "nearest")
  readonly property string selectionCriterion: setting("selectionCriterion", "closest")
  readonly property var pickedResult: root.pickAircraft(root.aircraft, root.selectionCriterion)
  readonly property var selectedAircraft: root.pickedResult.aircraft
  readonly property bool selectionFellBack: root.pickedResult.fellBack

  // Bar text is deliberately short (callsign only, no altitude): the bar's
  // Row layout sizes each slot from this Text's measured implicitWidth, and
  // longer strings were visibly wider once painted than what got measured,
  // overlapping the next widget. Full detail (altitude, speed, etc.) lives
  // in the popup instead.
  readonly property string label: {
    if (root.hasError) return "FLT --"
    if (root.displayMode === "count") return "FLT " + root.aircraft.length
    if (!root.selectedAircraft) return "FLT --"
    return root.selectedAircraft.callsign
  }

  readonly property string tooltip: {
    if (root.hasError) return "Flight Tracker: " + root.errorText
    if (!root.locationReady) return "Flight Tracker: locating..."
    if (root.aircraft.length === 0) return "Flight Tracker: no aircraft within " + root.radiusNm + " nm"
    if (root.displayMode !== "count") {
      var picked = root.selectedAircraft
      if (!picked) return root.aircraft.length + " aircraft within " + root.radiusNm + " nm"
      var prefix = ""
      if (root.selectionCriterion !== "closest") {
        prefix = root.selectionFellBack
          ? "No " + root.criterionLabel(root.selectionCriterion).toLowerCase() + " data, showing closest: "
          : root.criterionLabel(root.selectionCriterion) + ": "
      }
      return prefix + picked.callsign + " · " + picked.altLabel + " · " + root.aircraft.length + " aircraft within " + root.radiusNm + " nm"
    }
    return root.aircraft.length + " aircraft within " + root.radiusNm + " nm"
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function parseAircraft(raw) {
    var callsign = String(raw.flight || "").trim() || raw.r || raw.hex
    var altLabel = "Alt unknown"
    var altFt = null
    if (raw.alt_baro === "ground") {
      altLabel = "On ground"
      altFt = 0
    } else if (isFinite(raw.alt_baro)) {
      altLabel = raw.alt_baro >= 18000 ? "FL" + Math.round(raw.alt_baro / 100) : Math.round(raw.alt_baro) + " ft"
      altFt = Number(raw.alt_baro)
    }
    return {
      hex: raw.hex,
      callsign: callsign,
      altLabel: altLabel,
      altFt: altFt,
      speedKt: isFinite(raw.gs) ? Math.round(raw.gs) : null,
      heading: isFinite(raw.track) ? raw.track : (isFinite(raw.true_heading) ? raw.true_heading : null),
      type: raw.desc || raw.t || "",
      registration: raw.r || "",
      distNm: Number(raw.dst),
      squawk: raw.squawk || ""
    }
  }

  // Every network producer is built here. Both bounds are external to the QML
  // side on purpose: StdioCollector retains the whole of stdout before
  // onStreamFinished ever runs, so a size check up there is too late to bound
  // anything -- the memory is already committed inside omarchy-shell.
  //
  //   head -c   closes the pipe at the byte ceiling, at the producer
  //   timeout   is the deadline that still applies while curl is blocked in a
  //             syscall; curl's own --max-time is the inner limit
  //
  // cap+1 bytes are requested so a body sitting exactly at the ceiling stays
  // distinguishable from one that got cut off. The URL and every curl option
  // travel as argv entries -- nothing is ever spliced into the script text.
  function cappedCurl(url, capBytes, maxTimeSec, extraArgs) {
    var innerSec = Math.max(1, Math.round(maxTimeSec))
    var deadlineSec = Math.max(1, innerSec + 5)
    var command = ["timeout", "-k", "2", String(deadlineSec),
                   "sh", "-c", 'cap="$1"; shift; curl "$@" | head -c "$cap"', "sh",
                   String(capBytes + 1),
                   "-fsSL", "--max-time", String(innerSec)]
    if (extraArgs) command = command.concat(extraArgs)
    return command.concat(["--", String(url)])
  }

  // curl's exit status does not survive that pipeline -- head exits 0 whether
  // curl succeeded, 404'd, or was killed at the deadline -- so a blank body is
  // what tells us the producer failed, and onExited alone cannot be trusted to
  // report it. The length check is a secondary guard only: String.length counts
  // UTF-16 units rather than bytes, and head -c is the bound that actually
  // holds.
  function parseCappedJson(raw, capBytes) {
    var text = String(raw || "")
    if (text.trim() === "") throw new Error("empty response")
    if (text.length > capBytes) throw new Error("response exceeded " + capBytes + " bytes")
    return JSON.parse(text)
  }

  function parseAircraftList(raw) {
    var response = root.parseCappedJson(raw, root.flightsCapBytes)
    var list = response.ac || []
    var result = []
    for (var i = 0; i < list.length; i++) result.push(parseAircraft(list[i]))
    result.sort(function(a, b) {
      var da = isFinite(a.distNm) ? a.distNm : Infinity
      var db = isFinite(b.distNm) ? b.distNm : Infinity
      return da - db
    })
    return result
  }

  function criterionLabel(criterion) {
    switch (criterion) {
      case "lowest": return "Lowest"
      case "highest": return "Highest"
      case "fastest": return "Fastest"
      case "slowest": return "Slowest"
      default: return "Closest"
    }
  }

  // list is assumed already distance-sorted ascending (parseAircraftList's output).
  function pickAircraft(list, criterion) {
    if (!list || list.length === 0) return { aircraft: null, fellBack: false }
    if (criterion === "closest") return { aircraft: list[0], fellBack: false }

    var candidates, compare
    if (criterion === "lowest") {
      candidates = list.filter(function(a) { return a.altFt !== null })
      compare = function(a, b) { return a.altFt - b.altFt }
    } else if (criterion === "highest") {
      candidates = list.filter(function(a) { return a.altFt !== null })
      compare = function(a, b) { return b.altFt - a.altFt }
    } else if (criterion === "fastest") {
      candidates = list.filter(function(a) { return a.speedKt !== null })
      compare = function(a, b) { return b.speedKt - a.speedKt }
    } else if (criterion === "slowest") {
      candidates = list.filter(function(a) { return a.speedKt !== null })
      compare = function(a, b) { return a.speedKt - b.speedKt }
    } else {
      return { aircraft: list[0], fellBack: false }
    }

    if (candidates.length === 0) return { aircraft: list[0], fellBack: true }
    return { aircraft: candidates.slice().sort(compare)[0], fellBack: false }
  }

  function dataUpdatedLabel() {
    if (root.lastUpdatedMs <= 0) return "Waiting for data"
    if (root.hasError) return "Offline · " + root.relativeUpdateAge()
    return "Updated " + root.relativeUpdateAge()
  }

  function relativeUpdateAge() {
    var elapsedMinutes = Math.max(0, Math.floor((root.statusClockMs - root.lastUpdatedMs) / 60000))
    if (elapsedMinutes < 1) return "just now"
    if (elapsedMinutes < 60) return elapsedMinutes + "m ago"
    var elapsedHours = Math.floor(elapsedMinutes / 60)
    return elapsedHours + "h ago"
  }

  function refresh() {
    fetchLocation()
    fetchFlights()
  }

  function fetchFlights() {
    if (root.loading || !root.locationReady) return
    root.loading = true
    root.hasError = false
    flightsProcess.command = root.cappedCurl(
      "https://opendata.adsb.fi/api/v3/lat/" + root.latitude + "/lon/" + root.longitude + "/dist/" + root.radiusNm,
      root.flightsCapBytes, 15)
    flightsProcess.running = true
  }

  function fetchLocation() {
    if (root.manualOverride || locationProcess.running) return
    locationProcess.running = true
  }

  function searchCity() {
    var query = String(root.cityInput || "").trim()
    if (query === "" || citySearchProcess.running) return
    root.searchingCity = true
    root.cityResults = []
    citySearchProcess.command = root.cappedCurl(
      "https://nominatim.openstreetmap.org/search?format=jsonv2&addressdetails=1&limit=5&q=" + encodeURIComponent(query),
      root.citySearchCapBytes, 20, ["-A", "Flight-Tracker/1.0"])
    citySearchProcess.running = true
  }

  function selectCity(result) {
    var nextLatitude = Number(result.lat)
    var nextLongitude = Number(result.lon)
    if (!isFinite(nextLatitude) || !isFinite(nextLongitude)) return
    root.latitude = nextLatitude
    root.longitude = nextLongitude
    root.locationLabel = result.display_name || "Selected city"
    root.locationReady = true
    root.manualOverride = true
    root.cityResults = []
    root.searchingCity = false
    root.cityInput = ""
    root.loading = false
    root.fetchFlights()
  }

  function useCurrentLocation() {
    root.manualOverride = false
    root.locationReady = false
    root.loading = false
    root.fetchLocation()
  }

  // Persists one settings key via the shell's config store (shell.json), and
  // mirrors it into the local `settings` property immediately so bound
  // readonly properties (radiusNm, selectionCriterion, etc.) pick it up
  // without waiting for the round-trip. This never calls fetchFlights(): a
  // radius/refresh change only takes effect the next time the Timer or a
  // manual reload triggers a fetch, keeping requests within adsb.fi's rate
  // limit; selectionCriterion/displayMode changes are pure client-side
  // re-picks of already-loaded data, so they always feel instant regardless.
  function updateSetting(key, value) {
    var merged = Object.assign({}, root.settings || {})
    merged[key] = value
    root.settings = merged
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, merged)
  }

  function cycleSelectionCriterion() {
    var options = ["closest", "lowest", "highest", "fastest", "slowest"]
    var next = options[(options.indexOf(root.selectionCriterion) + 1) % options.length]
    root.updateSetting("selectionCriterion", next)
  }

  function cycleDisplayMode() {
    root.updateSetting("displayMode", root.displayMode === "count" ? "nearest" : "count")
  }

  function adjustRadius(deltaNm) {
    root.updateSetting("radiusNm", Math.min(250, Math.max(5, root.radiusNm + deltaNm)))
  }

  function adjustRefreshInterval(deltaSec) {
    root.updateSetting("refreshIntervalSec", Math.min(600, Math.max(30, root.refreshIntervalSec + deltaSec)))
  }

  IpcHandler {
    target: root.ipcTarget
    function open() { root.openFromHotkey() }
    function close() { root.close() }
    function show() { root.openFromHotkey() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refresh(); return "ok" }
  }

  Process {
    id: locationProcess
    command: root.cappedCurl("https://ipwho.is/", root.locationCapBytes, 15)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var location = root.parseCappedJson(text, root.locationCapBytes)
          if (!location.success || !isFinite(Number(location.latitude)) || !isFinite(Number(location.longitude))) throw new Error("location unavailable")
          root.latitude = Number(location.latitude)
          root.longitude = Number(location.longitude)
          root.locationLabel = (location.city || "Unknown city") + ", " + (location.country || "Unknown country")
          root.locationReady = true
          root.fetchFlights()
        } catch (error) {
          root.hasError = true
          root.errorText = "Location unavailable"
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.locationReady) {
        root.hasError = true
        root.errorText = "Location unavailable"
      }
    }
  }

  Process {
    id: flightsProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.aircraft = root.parseAircraftList(text)
          root.lastUpdatedMs = Date.now()
          root.hasError = false
        } catch (error) {
          root.hasError = true
          root.errorText = "Flight data unavailable"
        }
        root.loading = false
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.hasError = true
        root.errorText = "Flight data unavailable"
        root.loading = false
      }
    }
  }

  Process {
    id: citySearchProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var results = root.parseCappedJson(text, root.citySearchCapBytes)
          root.cityResults = Array.isArray(results) ? results : []
          root.hasError = false
        } catch (error) {
          root.cityResults = []
          root.hasError = true
          root.errorText = "City search unavailable"
        }
        root.searchingCity = false
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.cityResults = []
        root.searchingCity = false
        root.hasError = true
        root.errorText = "City search unavailable"
      }
    }
  }

  // Flight data: refreshes on the settings-driven cadence, clamped to a 30s
  // minimum to stay within adsb.fi's free-tier rate limit.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.fetchFlights()
  }

  // Location: fetched once at startup, then only refreshed occasionally
  // (independent of the flight-data cadence) so IP lookups don't add to the
  // adsb.fi request rate.
  Timer {
    interval: 1
    running: true
    repeat: false
    onTriggered: root.fetchLocation()
  }

  Timer {
    interval: 30 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.fetchLocation()
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.statusClockMs = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Column {
              id: titleGroup
              width: parent.width - settingsButton.width - refreshButton.width - updateStatus.implicitWidth - (parent.spacing * 3)
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.loading ? "FLIGHT TRACKER (updating...)" : "FLIGHT TRACKER"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "Nearby aircraft · adsb.fi"
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Text {
              textFormat: Text.PlainText
              id: updateStatus
              text: root.dataUpdatedLabel()
              color: Qt.darker(root.bar.foreground, 1.35)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              id: settingsButton
              text: root.settingsOpen ? "⚙ Close" : "⚙ Settings"
              implicitWidth: Style.space(84)
              implicitHeight: Style.space(30)
              onClicked: root.settingsOpen = !root.settingsOpen

              background: Rectangle {
                color: root.settingsOpen ? Qt.darker(root.bar.foreground, 4) : "transparent"
                border.color: root.bar.foreground
                border.width: 1
                radius: Style.space(4)
              }
            }

            Button {
              id: refreshButton
              text: "↻ Reload"
              implicitWidth: Style.space(84)
              implicitHeight: Style.space(30)
              enabled: !root.loading
              onClicked: root.refresh()

              background: Rectangle {
                color: "transparent"
                border.color: root.bar.foreground
                border.width: 1
                radius: Style.space(4)
                opacity: refreshButton.enabled ? 1.0 : 0.45
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.settingsOpen

            Text {
              textFormat: Text.PlainText
              text: "SETTINGS"
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                width: Style.space(140)
                text: "Aircraft selection"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: criterionButton
                text: root.criterionLabel(root.selectionCriterion) + " ▸"
                implicitHeight: Style.space(30)
                onClicked: root.cycleSelectionCriterion()
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                width: Style.space(140)
                text: "Bar display"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: displayModeButton
                text: root.displayMode === "count" ? "Count" : "Aircraft"
                implicitHeight: Style.space(30)
                onClicked: root.cycleDisplayMode()
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                width: Style.space(140)
                text: "Search radius"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: radiusDownButton
                text: "−"
                implicitWidth: Style.space(30)
                implicitHeight: Style.space(30)
                enabled: root.radiusNm > 5
                onClicked: root.adjustRadius(-5)
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                  opacity: radiusDownButton.enabled ? 1.0 : 0.45
                }
              }

              Text {
                textFormat: Text.PlainText
                width: Style.space(56)
                text: root.radiusNm + " nm"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: radiusUpButton
                text: "+"
                implicitWidth: Style.space(30)
                implicitHeight: Style.space(30)
                enabled: root.radiusNm < 250
                onClicked: root.adjustRadius(5)
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                  opacity: radiusUpButton.enabled ? 1.0 : 0.45
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                width: Style.space(140)
                text: "Refresh interval"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: refreshDownButton
                text: "−"
                implicitWidth: Style.space(30)
                implicitHeight: Style.space(30)
                enabled: root.refreshIntervalSec > 30
                onClicked: root.adjustRefreshInterval(-10)
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                  opacity: refreshDownButton.enabled ? 1.0 : 0.45
                }
              }

              Text {
                textFormat: Text.PlainText
                width: Style.space(56)
                text: root.refreshIntervalSec + "s"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: refreshUpButton
                text: "+"
                implicitWidth: Style.space(30)
                implicitHeight: Style.space(30)
                enabled: root.refreshIntervalSec < 600
                onClicked: root.adjustRefreshInterval(10)
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                  opacity: refreshUpButton.enabled ? 1.0 : 0.45
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Radius & refresh changes apply on the next scheduled update, not immediately — keeps requests within adsb.fi's rate limit."
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: "LOCATION"
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.locationLabel + (root.manualOverride ? "" : " (IP approx.)")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.locationReady ? (root.latitude.toFixed(4) + ", " + root.longitude.toFixed(4)) : "Locating..."
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              text: "Radius: " + root.radiusNm + " nm · Refresh: " + root.refreshIntervalSec + "s"
                  + (root.displayMode !== "count" ? " · Showing: " + root.criterionLabel(root.selectionCriterion) : "")
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              text: "SEARCH ANOTHER CITY"
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: cityField
                width: parent.width
                placeholderText: "Type a city"
                text: root.cityInput
                onTextChanged: root.cityInput = text
                onAccepted: root.searchCity()
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  text: root.searchingCity ? "⌕ ..." : "⌕ Search"
                  implicitHeight: Style.space(30)
                  enabled: !root.searchingCity
                  onClicked: root.searchCity()
                  background: Rectangle {
                    color: "transparent"
                    border.color: root.bar.foreground
                    border.width: 1
                    radius: Style.space(4)
                  }
                }

                Button {
                  text: "⌖ Use current"
                  implicitHeight: Style.space(30)
                  visible: root.manualOverride
                  onClicked: root.useCurrentLocation()
                  background: Rectangle {
                    color: "transparent"
                    border.color: root.bar.foreground
                    border.width: 1
                    radius: Style.space(4)
                  }
                }
              }
            }

            Repeater {
              model: root.cityResults

              Item {
                required property var modelData
                width: contentColumn.width
                implicitHeight: cityResultText.implicitHeight + Style.space(8)

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectCity(modelData)
                }

                Text {
                  textFormat: Text.PlainText
                  id: cityResultText
                  width: parent.width
                  text: modelData.display_name || "Unnamed result"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.hasError ? root.errorText : (root.aircraft.length > 0 ? root.aircraft.length + " AIRCRAFT IN RANGE" : "NO AIRCRAFT IN RANGE")
            color: Qt.darker(root.bar.foreground, 1.25)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          Repeater {
            model: root.aircraft

            Item {
              required property var modelData
              readonly property bool isSelected: root.selectedAircraft !== null && modelData.hex === root.selectedAircraft.hex
              width: contentColumn.width
              implicitHeight: aircraftColumn.implicitHeight

              Column {
                id: aircraftColumn
                width: parent.width
                spacing: Style.space(4)

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    id: callsignLabel
                    text: (isSelected ? "★ " : "") + modelData.callsign
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width - callsignLabel.width - parent.spacing
                    text: (isFinite(modelData.distNm) ? modelData.distNm.toFixed(1) + " nm" : "Distance unknown") + "  ·  " + modelData.altLabel
                    color: Qt.darker(root.bar.foreground, 1.25)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: [
                    modelData.type,
                    modelData.registration,
                    modelData.speedKt !== null ? modelData.speedKt + " kt" : "",
                    modelData.heading !== null ? Math.round(modelData.heading) + "°" : ""
                  ].filter(function(part) { return part !== "" }).join(" · ") || "No details"
                  color: Qt.darker(root.bar.foreground, 1.25)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }
      }
    }
  }
}
