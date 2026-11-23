.pragma library

// The four origins this plugin is allowed to talk to -- the same four the
// README names. Every URL built below is a literal with only numbers or an
// A-Z0-9 callsign spliced into it, so nothing here is chosen by a response
// today; the allowlist is enforced in cappedCurl() anyway, so a call site
// added later cannot reach a host that was never reviewed. Each entry ends
// in "/" on purpose: a prefix test against it fixes the whole authority, so
// a lookalike such as https://ipwho.is.evil.example/ cannot match.
var ENDPOINT_ALLOWLIST = [
  "https://opendata.adsb.fi/",
  "https://api.adsbdb.com/",
  "https://ipwho.is/",
  "https://nominatim.openstreetmap.org/"
]

function allowlistedEndpoint(url) {
  var text = String(url)
  for (var i = 0; i < ENDPOINT_ALLOWLIST.length; i++)
    if (text.indexOf(ENDPOINT_ALLOWLIST[i]) === 0) return true
  return false
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

// A pinned location round-trips through shell.json, where it can be edited by
// hand, so it is range-checked on the way back in rather than trusted. An
// out-of-range pair would otherwise build a scan URL no endpoint answers, and
// the panel would sit on "Waiting for data" with nothing saying why.
function validCoordinates(lat, lon) {
  return isFinite(lat) && isFinite(lon)
      && Math.abs(lat) <= 90 && Math.abs(lon) <= 180
}

function parseAircraft(raw, origin) {
  var callsign = sanitizeIdentifier(raw.flight, 10)
      || sanitizeIdentifier(raw.r, 10)
      || sanitizeIdentifier(raw.hex, 10)
  var altValue = numberOrNaN(raw.alt_baro)
  var altLabel = "Alt unknown"
  var altFt = null
  if (raw.alt_baro === "ground") {
    altLabel = "On ground"
    altFt = 0
  } else if (isFinite(altValue)) {
    altLabel = altValue >= 18000 ? "FL" + Math.round(altValue / 100) : Math.round(altValue) + " ft"
    altFt = altValue
  }

  var latitude = numberOrNaN(raw.lat)
  var longitude = numberOrNaN(raw.lon)
  var speed = numberOrNaN(raw.gs)
  var groundTrack = numberOrNaN(raw.track)
  var trueHeading = numberOrNaN(raw.true_heading)

  // "dst" (distance from the query point) only exists on the radius
  // endpoint. The callsign endpoint that track mode uses always sends it as
  // null, so the distance is computed from the aircraft's own position
  // instead -- there is no query point for it to have been measured from.
  var distance = numberOrNaN(raw.dst)
  if (!isFinite(distance) && origin)
    distance = greatCircleNm(origin.lat, origin.lon, latitude, longitude)

  return {
    hex: sanitizeIdentifier(raw.hex, 8),
    callsign: callsign,
    altLabel: altLabel,
    altFt: altFt,
    lat: latitude,
    lon: longitude,
    speedKt: isFinite(speed) ? Math.round(speed) : null,
    heading: isFinite(groundTrack) ? groundTrack : (isFinite(trueHeading) ? trueHeading : null),
    type: sanitizeText(raw.desc, 60) || sanitizeText(raw.t, 60),
    registration: sanitizeIdentifier(raw.r, 10),
    distNm: distance,
    squawk: sanitizeIdentifier(raw.squawk, 4)
  }
}

function parseAirport(raw) {
  if (!raw) return null
  var latitude = numberOrNaN(raw.latitude)
  var longitude = numberOrNaN(raw.longitude)
  if (!isFinite(latitude) || !isFinite(longitude)) return null
  return {
    code: sanitizeIdentifier(raw.iata_code, 4)
        || sanitizeIdentifier(raw.icao_code, 4)
        || "???",
    icao: sanitizeIdentifier(raw.icao_code, 4),
    name: sanitizeText(raw.name, 80),
    city: sanitizeText(raw.municipality, 60),
    country: sanitizeText(raw.country_name, 60),
    lat: latitude,
    lon: longitude
  }
}

function parseRoute(raw, capBytes) {
  var response = parseCappedJson(raw, capBytes)
  var flightroute = (response && response.response) ? response.response.flightroute : null
  if (!flightroute) throw new Error("no route on file")
  var origin = parseAirport(flightroute.origin)
  var destination = parseAirport(flightroute.destination)
  if (!origin || !destination) throw new Error("incomplete route")
  var airline = flightroute.airline ? sanitizeText(flightroute.airline.name, 60) : ""
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

// Distinct from normalizeCallsign above, which exists to make a value safe as
// a URL *path segment*. This one makes upstream identifiers safe as *text*.
// Callsigns, registrations, hex codes and airport codes are all short,
// fixed-alphabet identifiers, so they are whitelisted rather than escaped:
// whatever an upstream sends, what this plugin carries is [A-Z0-9-] only.
// The hyphen is kept because registrations need it (D-AIGW, C-FZXI).
// Free text -- aircraft types, airport and airline names, cities -- cannot be
// whitelisted to an alphabet without destroying it ("AIRBUS A-330-900",
// "Arnavutköy"), so the markup-significant characters are removed instead.
// These fields render only in this plugin's own panel, where every Text is
// pinned to PlainText, so this is the second layer rather than the first;
// it exists so that no network-sourced string is carried around holding
// markup, whichever sink a later edit points it at.
function sanitizeText(raw, maxLength) {
  return String(raw === undefined || raw === null ? "" : raw)
    .replace(/[<>&]/g, " ")
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .substring(0, maxLength)
    .trim()
}

function sanitizeIdentifier(raw, maxLength) {
  return String(raw === undefined || raw === null ? "" : raw)
    .toUpperCase().replace(/[^A-Z0-9-]/g, "").substring(0, maxLength)
}

// omarchy-shell renders a bar widget's label through the Text in
// Ui/WidgetButton.qml and its tooltip through the one in plugins/bar/Bar.qml.
// Neither sets textFormat, so both are Qt's default Text.AutoText, which
// sniffs its input and renders HTML -- including <img src="http://...">,
// which performs a network fetch from inside the shell process.
//
// Pinning Text.PlainText on this plugin's own Text elements cannot cover
// that: the Text doing the rendering belongs to the shell, not to the
// plugin, and the plugin has no way to set a property on it. So the boundary
// itself is the place to neutralise -- every string leaving here for the bar
// goes through this, which is why it is applied to `label` and `tooltip`
// wholesale rather than to the individual fields that feed them. Anything
// added to either of those later is covered without a further edit.
function barSafe(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/[<>&]/g, " ")
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .substring(0, 200)
}

var EARTH_RADIUS_NM = 3440.065

function greatCircleNm(lat1, lon1, lat2, lon2) {
  if (!isFinite(lat1) || !isFinite(lon1) || !isFinite(lat2) || !isFinite(lon2)) return NaN
  var toRad = Math.PI / 180
  var dLat = (lat2 - lat1) * toRad
  var dLon = (lon2 - lon1) * toRad
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
        + Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) * Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return 2 * EARTH_RADIUS_NM * Math.asin(Math.min(1, Math.sqrt(a)))
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
  var travelled = greatCircleNm(route.origin.lat, route.origin.lon, ac.lat, ac.lon)
  var remaining = greatCircleNm(ac.lat, ac.lon, route.destination.lat, route.destination.lon)
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
//
// The destination is bounded here too, in three ways that only matter once
// one of the four services misbehaves:
//
//   allowlist  the origin has to be one of the four in endpointAllowlist, so
//              only a reviewed host is ever contacted
//   -fsS       no -L: redirects are not followed at all. With -L, a 3xx from
//              any of those services -- compromised, hijacked, or merely
//              misconfigured -- would move this curl to whatever Location it
//              named, including 127.0.0.1, 169.254.169.254 or an RFC1918
//              address, and the allowlist above only ever sees the first hop.
//   --proto    the request itself is refused unless it is https, so no other
//              scheme can be reached through this helper either.
//
// A refused origin returns a producer that exits non-zero with empty stdout,
// which is exactly the shape a failed fetch already has here -- the caller
// falls back to the values it is already showing instead of the plugin
// growing a second kind of failure.
function cappedCurl(url, capBytes, maxTimeSec, extraArgs) {
  if (!allowlistedEndpoint(url)) return ["sh", "-c", "exit 1"]
  var innerSec = Math.max(1, Math.round(maxTimeSec))
  var deadlineSec = Math.max(1, innerSec + 5)
  var command = ["timeout", "-k", "2", String(deadlineSec),
                 "sh", "-c", 'cap="$1"; shift; curl "$@" | head -c "$cap"', "sh",
                 String(capBytes + 1),
                 "-fsS", "--proto", "=https", "--max-time", String(innerSec)]
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

function parseAircraftList(raw, capBytes, maxAircraft, origin) {
  var response = parseCappedJson(raw, capBytes)
  var list = response.ac || []
  // Clamp the element count ahead of the parse/sort, the same way the byte
  // ceilings clamp the response ahead of JSON.parse -- a reply that stays
  // under flightsCapBytes can still carry far more entries than any real scan.
  if (list.length > maxAircraft) list = list.slice(0, maxAircraft)
  var result = []
  for (var i = 0; i < list.length; i++) result.push(parseAircraft(list[i], origin))
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
