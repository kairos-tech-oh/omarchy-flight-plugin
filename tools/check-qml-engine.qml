import QtQuick
import "../FlightLogic.js" as Logic

QtObject {
  function fail(code) {
    Qt.exit(code)
    return false
  }

  Component.onCompleted: {
    if (!Logic.allowlistedEndpoint("https://api.adsbdb.com/v0/x")) return fail(1)
    if (Logic.allowlistedEndpoint("https://evil.example/?u=https://ipwho.is/")) return fail(2)
    if (!isNaN(Logic.numberOrNaN(null)) || Logic.numberOrNaN("12.5") !== 12.5) return fail(3)
    if (Logic.normalizeCallsign("../ual 123/") !== "UAL123") return fail(4)
    if (/[<>&]/.test(Logic.sanitizeText("<img src=x>&", 60))) return fail(5)
    if (Logic.sanitizeText("Arnavutköy", 60) !== "Arnavutköy") return fail(6)
    if (Logic.barSafe("x".repeat(500)).length !== 200) return fail(7)

    var nm = Logic.greatCircleNm(40.6413, -73.7781, 51.47, -0.4543)
    if (Math.abs(nm - 2990) > 15) return fail(10)
    if (Logic.greatCircleNm(10, 20, 10, 20) !== 0) return fail(11)

    var ac = Logic.parseAircraft({ hex: "a", alt_baro: 18000, gs: "451.6", lat: 51.47, lon: -0.4543, dst: null }, { lat: 40.6413, lon: -73.7781 })
    if (ac.altLabel !== "FL180" || ac.speedKt !== 452) return fail(20)
    if (Math.abs(ac.distNm - nm) > 1e-6) return fail(21)
    if (Logic.parseAircraft({ hex: "a", alt_baro: "ground" }, null).altFt !== 0) return fail(22)

    var route = { origin: { lat: 40.6413, lon: -73.7781 }, destination: { lat: 51.47, lon: -0.4543 } }
    if (Math.abs(Logic.routeProgress({ lat: 51.47, lon: -0.4543 }, route).fraction - 1) > 1e-9) return fail(30)
    if (Logic.routeProgress({ lat: NaN, lon: 0 }, route).valid) return fail(31)

    var cmd = Logic.cappedCurl("https://api.adsbdb.com/x", 10, 0)
    if (cmd[cmd.indexOf("--max-time") + 1] !== "1" || cmd[3] !== "6") return fail(40)
    if (cmd.join(" ") !== Logic.cappedCurl("https://api.adsbdb.com/x", 10, 0).join(" ")) return fail(41)
    if (Logic.cappedCurl("https://evil.example/", 10, 5).join(" ") !== "sh -c exit 1") return fail(42)

    var list = Logic.parseAircraftList(JSON.stringify({ ac: [{ hex: "far", dst: 9 }, { hex: "none" }, { hex: "near", dst: 1 }] }), 1048576, 2000, null)
    if (list.map(function (a) { return a.hex }).join(",") !== "NEAR,FAR,NONE") return fail(50)
    if (Logic.pickAircraft(list, "lowest").fellBack !== true) return fail(51)

    Qt.exit(0)
  }
}
