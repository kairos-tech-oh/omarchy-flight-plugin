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

  // Track-mode state. trackedAircraft holds the last position that actually
  // arrived, not the last response: a callsign that resolves to no aircraft is
  // routine -- the flight landed, or it is crossing a gap in receiver coverage
  // -- and blanking the widget on each of those would make an ocean crossing
  // flicker for hours. trackPendingFor/routePendingFor record which callsign a
  // request was launched for, so a reply that lands after the user has already
  // switched flights is discarded instead of being shown against the new one.
  property var trackedAircraft: null
  property var trackedRoute: null
  property string routeForCallsign: ""
  property string routeAttemptedFor: ""
  property string trackPendingFor: ""
  property string routePendingFor: ""
  property bool routeUnavailable: false
  property real trackedSeenMs: 0
  property bool trackLoading: false
  property bool trackSignalLost: false
  property string trackError: ""
  property string trackInput: ""

  // Byte ceilings for each network response, sized from measured replies so a
  // legitimate one is never truncated. At the 250 nm maximum radius adsb.fi
  // returned 299 KiB over New York, 247 KiB over Chicago, 246 KiB over Los
  // Angeles, 111 KiB over London; 1 MiB leaves better than 3x headroom over
  // the busiest of those and is still a hard bound on what the shell holds.
  // ipwho.is returned 963 bytes and Nominatim 3.0 KiB at limit=5. The two
  // track-mode replies are far smaller still: adsb.fi's callsign endpoint
  // returned 610-700 bytes for a single match and 101 bytes for none, and
  // adsbdb 694 bytes for a route, so 64 KiB is roughly 90x headroom on each.
  readonly property int locationCapBytes: 65536
  readonly property int flightsCapBytes: 1048576
  readonly property int citySearchCapBytes: 65536
  readonly property int trackedFlightCapBytes: 65536
  readonly property int routeCapBytes: 65536

  readonly property int refreshIntervalSec: Math.max(30, parseInt(setting("refreshIntervalSec", 30), 10) || 30)
  readonly property int radiusNm: Math.min(250, Math.max(1, parseInt(setting("radiusNm", 25), 10) || 25))
  readonly property string displayMode: setting("displayMode", "nearest")
  readonly property string selectionCriterion: setting("selectionCriterion", "closest")
  readonly property string trackCallsign: root.normalizeCallsign(setting("trackCallsign", ""))
  readonly property bool tracking: root.displayMode === "track" && root.trackCallsign !== ""

  // Route data is only ever read back through this, so a route left over from
  // the previously tracked callsign can never be drawn against the current one.
  readonly property var activeRoute: (root.trackedRoute && root.routeForCallsign === root.trackCallsign)
      ? root.trackedRoute : null
  readonly property var trackProgress: root.routeProgress(root.trackedAircraft, root.activeRoute)

  // Consumed by BarWidget.qml to draw the bar-side progress indicator.
  readonly property bool showBarProgress: root.tracking && root.trackProgress.valid
  readonly property real barProgress: root.trackProgress.valid ? root.trackProgress.fraction : -1
  readonly property bool barProgressStale: root.trackSignalLost || root.trackError !== ""
  readonly property var pickedResult: root.pickAircraft(root.aircraft, root.selectionCriterion)
  readonly property var selectedAircraft: root.pickedResult.aircraft
  readonly property bool selectionFellBack: root.pickedResult.fellBack

  // Bar text is deliberately short (callsign only, no altitude): the bar's
  // Row layout sizes each slot from this Text's measured implicitWidth, and
  // longer strings were visibly wider once painted than what got measured,
  // overlapping the next widget. Full detail (altitude, speed, etc.) lives
  // in the popup instead.
  readonly property string label: {
    if (root.displayMode === "track") return root.trackCallsign !== "" ? root.trackCallsign : "FLT --"
    if (root.hasError) return "FLT --"
    if (root.displayMode === "count") return "FLT " + root.aircraft.length
    if (!root.selectedAircraft) return "FLT --"
    return root.selectedAircraft.callsign
  }

  readonly property string tooltip: {
    if (root.displayMode === "track") return root.trackTooltip()
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

  // Number(null) is 0 and isFinite(null) is true, so a JSON null in a numeric
  // field otherwise reads as a genuine measurement of zero: a null "dst"
  // becomes an aircraft 0.0 nm away, a null latitude becomes a point in the
  // Gulf of Guinea, a null "alt_baro" becomes sea level. Every numeric field
  // taken off a response goes through here rather than through Number()
  // directly, so that whole class cannot come back through a later edit.
  function numberOrNaN(value) {
    if (value === null || value === undefined || value === "") return NaN
    var parsed = Number(value)
    return isFinite(parsed) ? parsed : NaN
  }

  function parseAircraft(raw) {
    var callsign = String(raw.flight || "").trim() || raw.r || raw.hex
    var altValue = root.numberOrNaN(raw.alt_baro)
    var altLabel = "Alt unknown"
    var altFt = null
    if (raw.alt_baro === "ground") {
      altLabel = "On ground"
      altFt = 0
    } else if (isFinite(altValue)) {
      altLabel = altValue >= 18000 ? "FL" + Math.round(altValue / 100) : Math.round(altValue) + " ft"
      altFt = altValue
    }

    var latitude = root.numberOrNaN(raw.lat)
    var longitude = root.numberOrNaN(raw.lon)
    var speed = root.numberOrNaN(raw.gs)
    var groundTrack = root.numberOrNaN(raw.track)
    var trueHeading = root.numberOrNaN(raw.true_heading)

    // "dst" (distance from the query point) only exists on the radius
    // endpoint. The callsign endpoint that track mode uses always sends it as
    // null, so the distance is computed from the aircraft's own position
    // instead -- there is no query point for it to have been measured from.
    var distance = root.numberOrNaN(raw.dst)
    if (!isFinite(distance) && root.locationReady)
      distance = root.greatCircleNm(root.latitude, root.longitude, latitude, longitude)

    return {
      hex: raw.hex,
      callsign: callsign,
      altLabel: altLabel,
      altFt: altFt,
      lat: latitude,
      lon: longitude,
      speedKt: isFinite(speed) ? Math.round(speed) : null,
      heading: isFinite(groundTrack) ? groundTrack : (isFinite(trueHeading) ? trueHeading : null),
      type: raw.desc || raw.t || "",
      registration: raw.r || "",
      distNm: distance,
      squawk: raw.squawk || ""
    }
  }

  function parseAirport(raw) {
    if (!raw) return null
    var latitude = root.numberOrNaN(raw.latitude)
    var longitude = root.numberOrNaN(raw.longitude)
    if (!isFinite(latitude) || !isFinite(longitude)) return null
    return {
      code: String(raw.iata_code || raw.icao_code || "???"),
      icao: String(raw.icao_code || ""),
      name: String(raw.name || ""),
      city: String(raw.municipality || ""),
      country: String(raw.country_name || ""),
      lat: latitude,
      lon: longitude
    }
  }

  function parseRoute(raw) {
    var response = root.parseCappedJson(raw, root.routeCapBytes)
    var flightroute = (response && response.response) ? response.response.flightroute : null
    if (!flightroute) throw new Error("no route on file")
    var origin = root.parseAirport(flightroute.origin)
    var destination = root.parseAirport(flightroute.destination)
    if (!origin || !destination) throw new Error("incomplete route")
    var airline = flightroute.airline ? String(flightroute.airline.name || "") : ""
    return { origin: origin, destination: destination, airline: airline }
  }

  // Callsigns come from a text field and are spliced into a URL *path*, where
  // a "../" would walk straight off the endpoint. Everything outside A-Z0-9 is
  // dropped rather than escaped -- no real callsign contains anything else --
  // and the result is length-bounded, so what reaches the URL is always a
  // single literal path segment. Applied both when storing the setting and
  // again when reading it back, so a value edited into shell.json by hand is
  // sanitised too.
  function normalizeCallsign(raw) {
    return String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "").substring(0, 8)
  }

  readonly property real earthRadiusNm: 3440.065

  function greatCircleNm(lat1, lon1, lat2, lon2) {
    if (!isFinite(lat1) || !isFinite(lon1) || !isFinite(lat2) || !isFinite(lon2)) return NaN
    var toRad = Math.PI / 180
    var dLat = (lat2 - lat1) * toRad
    var dLon = (lon2 - lon1) * toRad
    var a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
          + Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) * Math.sin(dLon / 2) * Math.sin(dLon / 2)
    return 2 * root.earthRadiusNm * Math.asin(Math.min(1, Math.sqrt(a)))
  }

  // Progress is travelled / (travelled + remaining), not travelled / route
  // length. Both legs here are great-circle, but the path actually flown never
  // is -- airways, weather deviations and holding all add distance -- so
  // dividing by the great-circle route length reads past 100% on an ordinary
  // flight. This ratio form cannot: it is 0 over the origin, exactly 1 over the
  // destination, and stays inside that range whatever detour was flown.
  function routeProgress(ac, route) {
    var blank = { valid: false, fraction: 0, travelledNm: NaN, remainingNm: NaN }
    if (!ac || !route) return blank
    if (!isFinite(ac.lat) || !isFinite(ac.lon)) return blank
    var travelled = root.greatCircleNm(route.origin.lat, route.origin.lon, ac.lat, ac.lon)
    var remaining = root.greatCircleNm(ac.lat, ac.lon, route.destination.lat, route.destination.lon)
    if (!isFinite(travelled) || !isFinite(remaining)) return blank
    var span = travelled + remaining
    if (span < 1) return blank
    return {
      valid: true,
      fraction: Math.max(0, Math.min(1, travelled / span)),
      travelledNm: travelled,
      remainingNm: remaining
    }
  }

  function trackSignalAgeLabel() {
    if (root.trackedSeenMs <= 0) return "no signal yet"
    var minutes = Math.max(0, Math.floor((root.statusClockMs - root.trackedSeenMs) / 60000))
    if (minutes < 1) return "no signal"
    if (minutes < 60) return "no signal " + minutes + "m"
    return "no signal " + Math.floor(minutes / 60) + "h"
  }

  function trackProgressPercent() {
    return Math.round(root.trackProgress.fraction * 100) + "%"
  }

  function trackTooltip() {
    if (root.trackCallsign === "")
      return "Flight Tracker: no callsign set - open the panel to track a flight"
    var parts = [root.trackCallsign]
    if (root.trackProgress.valid) parts.push(root.trackProgressPercent())
    if (root.activeRoute)
      parts.push(root.activeRoute.origin.code + " → " + root.activeRoute.destination.code)
    else if (root.routeUnavailable) parts.push("no route data")
    if (root.trackError !== "") parts.push(root.trackError)
    else if (root.trackSignalLost) parts.push(root.trackSignalAgeLabel())
    else if (root.trackedAircraft) parts.push(root.trackedAircraft.altLabel)
    return parts.join(" · ")
  }

  function startTracking(callsign) {
    var normalized = root.normalizeCallsign(callsign)
    if (normalized === "") return
    root.trackInput = ""
    root.updateSettings({ trackCallsign: normalized, displayMode: "track" })
    // Covers re-tracking the callsign already set, where trackCallsign does not
    // change and onTrackCallsignChanged therefore never fires.
    root.fetchTrackedFlight()
  }

  // Every one of these is a property of one specific flight, so the reset
  // belongs to the callsign changing rather than to startTracking() -- the
  // callsign can also change from outside it, through the shell's settings or
  // an edit straight into shell.json. Without this, the previous flight's
  // altitude, type and registration keep rendering under the new callsign
  // until the first response for it arrives.
  onTrackCallsignChanged: {
    root.trackedAircraft = null
    root.trackedRoute = null
    root.routeForCallsign = ""
    root.routeAttemptedFor = ""
    root.routeUnavailable = false
    root.trackedSeenMs = 0
    root.trackSignalLost = false
    root.trackError = ""
    root.trackLoading = false
    if (root.tracking) root.fetchTrackedFlight()
  }

  // The callsign is deliberately kept when leaving track mode, so re-entering
  // resumes the same flight instead of asking for it again.
  function stopTracking() {
    root.trackError = ""
    root.trackSignalLost = false
    root.updateSettings({ displayMode: "nearest" })
    root.fetchFlights()
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

  // Reload is the one place both fetches run together: in track mode the
  // scheduled cycle only refreshes the tracked flight, which leaves the nearby
  // list frozen at whatever the last scan saw, and this is how the user thaws
  // it. Clearing routeAttemptedFor also makes this the deliberate retry for a
  // route lookup that previously came back empty.
  function refresh() {
    fetchLocation()
    if (root.tracking) {
      root.routeAttemptedFor = ""
      root.routeUnavailable = false
      root.fetchTrackedFlight()
    }
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

  function fetchTrackedFlight() {
    var callsign = root.normalizeCallsign(root.trackCallsign)
    if (callsign === "" || root.trackLoading) return
    root.trackLoading = true
    root.trackError = ""
    root.trackPendingFor = callsign
    trackedFlightProcess.command = root.cappedCurl(
      "https://opendata.adsb.fi/api/v2/callsign/" + callsign,
      root.trackedFlightCapBytes, 15)
    trackedFlightProcess.running = true
    root.fetchRoute()
  }

  // A route belongs to the callsign, not to the moment, so this runs once per
  // callsign rather than once per refresh cycle. A callsign adsbdb has no route
  // for answers 404 forever, and recording the attempt is what stops that
  // becoming a request every 30 seconds for as long as the flight is tracked;
  // Reload clears it when the user wants another try.
  function fetchRoute() {
    var callsign = root.normalizeCallsign(root.trackCallsign)
    if (callsign === "" || routeProcess.running) return
    if (root.routeAttemptedFor === callsign) return
    root.routeAttemptedFor = callsign
    root.routePendingFor = callsign
    routeProcess.command = root.cappedCurl(
      "https://api.adsbdb.com/v0/callsign/" + callsign,
      root.routeCapBytes, 15)
    routeProcess.running = true
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
    var patch = {}
    patch[key] = value
    root.updateSettings(patch)
  }

  // Entering track mode has to write two keys at once (the callsign and the
  // mode), and two sequential single-key writes would each build their patch
  // from a settings object the other had not landed in yet.
  function updateSettings(patch) {
    var merged = Object.assign({}, root.settings || {}, patch)
    root.settings = merged
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, merged)
  }

  function cycleSelectionCriterion() {
    var options = ["closest", "lowest", "highest", "fastest", "slowest"]
    var next = options[(options.indexOf(root.selectionCriterion) + 1) % options.length]
    root.updateSetting("selectionCriterion", next)
  }

  // Only cycles between the two scan displays. Track mode is not in the cycle
  // because it needs a callsign to mean anything, so it is entered from the
  // tracking controls below; pressing this while tracking leaves track mode.
  function cycleDisplayMode() {
    if (root.displayMode === "track") {
      root.stopTracking()
      return
    }
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

  Process {
    id: trackedFlightProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var response = root.parseCappedJson(text, root.trackedFlightCapBytes)
          if (root.trackPendingFor !== root.trackCallsign) {
            root.trackLoading = false
            return
          }
          var list = response.ac || []
          if (list.length > 0) {
            root.trackedAircraft = root.parseAircraft(list[0])
            root.trackedSeenMs = Date.now()
            root.trackSignalLost = false
          } else {
            // An empty list is not a failure. The flight has landed, or it is
            // over a stretch with no receiver coverage -- routine mid-ocean.
            // Whatever was last seen stays on screen, dimmed.
            root.trackSignalLost = true
          }
          root.trackError = ""
          root.lastUpdatedMs = Date.now()
        } catch (error) {
          root.trackError = "Flight data unavailable"
        }
        root.trackLoading = false
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.trackError = "Flight data unavailable"
        root.trackLoading = false
      }
    }
  }

  Process {
    id: routeProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var route = root.parseRoute(text)
          if (root.routePendingFor !== root.trackCallsign) return
          root.trackedRoute = route
          root.routeForCallsign = root.routePendingFor
          root.routeUnavailable = false
        } catch (error) {
          // adsbdb answers an unknown callsign with 404, which curl -f turns
          // into an empty body, which parseCappedJson throws on. So this is the
          // ordinary "no route on file" path -- common for GA registrations --
          // and not a condition worth an error banner.
          root.trackedRoute = null
          root.routeForCallsign = ""
          root.routeUnavailable = true
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.trackedRoute = null
        root.routeForCallsign = ""
        root.routeUnavailable = true
      }
    }
  }

  // Flight data: refreshes on the settings-driven cadence, clamped to a 30s
  // minimum to stay within adsb.fi's free-tier rate limit. Track mode swaps
  // which endpoint the cycle calls rather than adding a second call to it, so
  // the request rate is the same either way.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.tracking ? root.fetchTrackedFlight() : root.fetchFlights()
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
                text: root.displayMode === "track"
                    ? "Tracking one flight · adsb.fi + adsbdb"
                    : "Nearby aircraft · adsb.fi"
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
                text: root.displayMode === "track"
                    ? "Tracking ✕"
                    : (root.displayMode === "count" ? "Count" : "Aircraft")
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

            Text {
              textFormat: Text.PlainText
              text: "TRACK A FLIGHT"
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: trackField
                width: parent.width - trackButton.width - parent.spacing
                placeholderText: "Callsign, e.g. BAW123"
                text: root.trackInput
                onTextChanged: root.trackInput = text
                onAccepted: root.startTracking(root.trackInput)
              }

              Button {
                id: trackButton
                text: "✈ Track"
                implicitHeight: Style.space(30)
                enabled: root.normalizeCallsign(root.trackInput) !== ""
                onClicked: root.startTracking(root.trackInput)
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                  opacity: trackButton.enabled ? 1.0 : 0.45
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Track mode follows one flight anywhere in the world, ignoring the search radius, and shows its progress between departure and arrival. You can also click any aircraft in the list below to track it. While tracking, the nearby list stops updating on its own - use ↻ Reload to refresh it."
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
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

            // width + wrap rather than a bare Text: this line grows with the
            // settings it reports, and without a bound it runs straight past
            // the panel's edge instead of moving to a second line.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.displayMode === "track"
                  ? "Refresh: " + root.refreshIntervalSec + "s · Radius not used while tracking"
                  : "Radius: " + root.radiusNm + " nm · Refresh: " + root.refreshIntervalSec + "s"
                      + (root.displayMode === "nearest" ? " · Showing: " + root.criterionLabel(root.selectionCriterion) : "")
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
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

          Column {
            id: trackingSection
            width: parent.width
            spacing: Style.space(6)
            visible: root.displayMode === "track"

            Text {
              textFormat: Text.PlainText
              text: "TRACKING"
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.trackCallsign === ""
              text: "No callsign set. Open ⚙ Settings to enter one, or click an aircraft below."
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.trackCallsign !== ""

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  id: trackedCallsignLabel
                  text: root.trackCallsign
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width - trackedCallsignLabel.width - parent.spacing
                  text: {
                    if (root.trackError !== "") return root.trackError
                    if (root.trackSignalLost) return root.trackSignalAgeLabel()
                    if (!root.trackedAircraft) return root.trackLoading ? "Locating flight..." : "Waiting for data"
                    return root.trackedAircraft.altLabel
                  }
                  color: Qt.darker(root.bar.foreground, 1.25)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideLeft
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                visible: root.activeRoute !== null
                opacity: root.trackSignalLost ? 0.55 : 1.0

                Text {
                  textFormat: Text.PlainText
                  id: originCode
                  width: Style.space(44)
                  text: root.activeRoute ? root.activeRoute.origin.code : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                  width: parent.width - originCode.width - destinationCode.width - (parent.spacing * 2)
                  height: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter

                  Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: root.bar.foreground
                    opacity: 0.25
                  }

                  Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * (root.trackProgress.valid ? root.trackProgress.fraction : 0)
                    height: parent.height
                    radius: height / 2
                    color: root.bar.foreground

                    Behavior on width {
                      NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  id: destinationCode
                  width: Style.space(44)
                  text: root.activeRoute ? root.activeRoute.destination.code : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: root.activeRoute !== null
                text: {
                  if (!root.activeRoute) return ""
                  if (!root.trackProgress.valid) return "Progress unavailable — no position for this flight yet"
                  return root.trackProgressPercent() + " of the way · "
                      + Math.round(root.trackProgress.remainingNm) + " nm to run"
                }
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: root.activeRoute !== null
                text: {
                  if (!root.activeRoute) return ""
                  var from = root.activeRoute.origin.city || root.activeRoute.origin.name
                  var to = root.activeRoute.destination.city || root.activeRoute.destination.name
                  return from + " → " + to
                }
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: root.activeRoute === null
                text: root.routeUnavailable
                    ? "No route on file for this callsign — position is still tracked, but there is nothing to measure progress against."
                    : "Looking up route..."
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: root.trackedAircraft !== null
                text: {
                  if (!root.trackedAircraft) return ""
                  var ac = root.trackedAircraft
                  return [
                    ac.type,
                    ac.registration,
                    ac.speedKt !== null ? ac.speedKt + " kt" : "",
                    isFinite(ac.distNm) ? Math.round(ac.distNm) + " nm from you" : ""
                  ].filter(function(part) { return part !== "" }).join(" · ") || "No details"
                }
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }

              Button {
                id: stopTrackingButton
                text: "✕ Stop tracking"
                implicitHeight: Style.space(30)
                onClicked: root.stopTracking()
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: {
              if (root.hasError) return root.errorText
              var heading = root.aircraft.length > 0
                  ? root.aircraft.length + " AIRCRAFT IN RANGE"
                  : "NO AIRCRAFT IN RANGE"
              if (root.aircraft.length > 0) heading += root.tracking ? " (PAUSED · CLICK ONE TO TRACK)" : " · CLICK ONE TO TRACK"
              return heading
            }
            color: Qt.darker(root.bar.foreground, 1.25)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          Repeater {
            model: root.aircraft

            Item {
              required property var modelData
              readonly property bool isSelected: root.displayMode !== "track"
                  && root.selectedAircraft !== null && modelData.hex === root.selectedAircraft.hex
              readonly property bool isTracked: root.tracking && modelData.callsign === root.trackCallsign
              width: contentColumn.width
              implicitHeight: aircraftColumn.implicitHeight

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.startTracking(modelData.callsign)
              }

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
                    text: (isTracked ? "✈ " : (isSelected ? "★ " : "")) + modelData.callsign
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
