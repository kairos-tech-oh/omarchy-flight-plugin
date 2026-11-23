#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(path.join(__dirname, "..", "FlightLogic.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const L = {};
vm.runInNewContext(src + "\nthis.L = { ENDPOINT_ALLOWLIST, allowlistedEndpoint, numberOrNaN, validCoordinates, parseAircraft, parseAirport, parseRoute, normalizeCallsign, sanitizeText, sanitizeIdentifier, barSafe, greatCircleNm, routeProgress, cappedCurl, parseCappedJson, parseAircraftList, criterionLabel, pickAircraft };", L);
const F = L.L;

let failed = 0;
function check(name, cond, detail) {
  if (cond) console.log("ok   " + name);
  else { failed++; console.log("FAIL " + name + (detail === undefined ? "" : "  got " + JSON.stringify(detail))); }
}
function throws(fn) { try { fn(); return false; } catch (e) { return true; } }
const near = (a, b, eps) => Math.abs(a - b) <= eps;

check("allowlist accepts each listed origin", F.ENDPOINT_ALLOWLIST.every((u) => F.allowlistedEndpoint(u + "x")));
check("allowlist refuses a lookalike host", !F.allowlistedEndpoint("https://ipwho.is.evil.example/"));
check("allowlist refuses an allowed origin embedded later in the url", !F.allowlistedEndpoint("https://evil.example/?u=https://ipwho.is/"));
check("allowlist refuses plain http", !F.allowlistedEndpoint("http://opendata.adsb.fi/api"));
check("allowlist refuses empty and null", !F.allowlistedEndpoint("") && !F.allowlistedEndpoint(null));

check("numberOrNaN: null, undefined and empty are NaN", [null, undefined, ""].every((v) => Number.isNaN(F.numberOrNaN(v))));
check("numberOrNaN: numeric strings parse", F.numberOrNaN("12.5") === 12.5 && F.numberOrNaN(0) === 0);
check("numberOrNaN: junk and infinities are NaN", Number.isNaN(F.numberOrNaN("abc")) && Number.isNaN(F.numberOrNaN(Infinity)));

check("validCoordinates accepts the poles and antimeridian", F.validCoordinates(90, 180) && F.validCoordinates(-90, -180));
check("validCoordinates refuses out of range and NaN", !F.validCoordinates(91, 0) && !F.validCoordinates(0, 181) && !F.validCoordinates(NaN, 0));

check("sanitizeText strips tag-shaped input", F.sanitizeText('<img src="http://x">Boeing', 60).indexOf("<") < 0);
check("sanitizeText strips & and control characters", F.sanitizeText("A&B\nC\u0000D", 60) === "A B C D", F.sanitizeText("A&B\nC\u0000D", 60));
check("sanitizeText keeps non-ASCII free text", F.sanitizeText("Arnavutköy", 60) === "Arnavutköy");
check("sanitizeText truncates and trims", F.sanitizeText("  abcdef  ", 5) === "abc", F.sanitizeText("  abcdef  ", 5));
check("sanitizeText of null is empty", F.sanitizeText(null, 10) === "");

check("sanitizeIdentifier keeps A-Z0-9 and hyphen", F.sanitizeIdentifier("d-aigw<b>", 10) === "D-AIGWB", F.sanitizeIdentifier("d-aigw<b>", 10));
check("sanitizeIdentifier bounds length", F.sanitizeIdentifier("ABCDEFGHIJ", 4) === "ABCD");

check("normalizeCallsign drops path traversal", F.normalizeCallsign("../ual 123/") === "UAL123", F.normalizeCallsign("../ual 123/"));
check("normalizeCallsign drops hyphens and caps at 8", F.normalizeCallsign("AB-CDEFGHIJK") === "ABCDEFGH", F.normalizeCallsign("AB-CDEFGHIJK"));
check("normalizeCallsign of null is empty", F.normalizeCallsign(null) === "");

check("barSafe removes markup characters", !/[<>&]/.test(F.barSafe("<b>x</b> & y")));
check("barSafe removes newlines", F.barSafe("a\nb").indexOf("\n") < 0);
check("barSafe caps at 200 characters", F.barSafe("x".repeat(500)).length === 200);

const JFK = { lat: 40.6413, lon: -73.7781 }, LHR = { lat: 51.47, lon: -0.4543 };
const jfkLhr = F.greatCircleNm(JFK.lat, JFK.lon, LHR.lat, LHR.lon);
check("greatCircleNm JFK-LHR is about 2,990 nm", near(jfkLhr, 2990, 15), jfkLhr);
check("greatCircleNm is symmetric", near(jfkLhr, F.greatCircleNm(LHR.lat, LHR.lon, JFK.lat, JFK.lon), 1e-9));
check("greatCircleNm of a point to itself is 0", F.greatCircleNm(10, 20, 10, 20) === 0);
check("greatCircleNm with a missing coordinate is NaN", Number.isNaN(F.greatCircleNm(NaN, 0, 1, 1)));

const ground = F.parseAircraft({ hex: "abc123", flight: "UAL123 ", alt_baro: "ground", lat: 1, lon: 2, dst: 0.5 }, null);
check("parseAircraft: ground altitude", ground.altLabel === "On ground" && ground.altFt === 0, ground);
const high = F.parseAircraft({ hex: "a", alt_baro: 35049, gs: "451.6", track: 90, true_heading: 80, dst: 3 }, null);
check("parseAircraft: flight level at or above 18,000 ft", high.altLabel === "FL350" && high.altFt === 35049, high.altLabel);
check("parseAircraft: speed rounded, ground track preferred", high.speedKt === 452 && high.heading === 90, high);
check("parseAircraft: exactly 18,000 ft is a flight level", F.parseAircraft({ hex: "a", alt_baro: 18000 }, null).altLabel === "FL180");
check("parseAircraft: 17,999 ft stays in feet", F.parseAircraft({ hex: "a", alt_baro: 17999 }, null).altLabel === "17999 ft");
const low = F.parseAircraft({ hex: "a", alt_baro: 2500.4 }, null);
check("parseAircraft: feet below 18,000 ft", low.altLabel === "2500 ft", low.altLabel);
const unknown = F.parseAircraft({ hex: "a", alt_baro: null, lat: null, gs: null }, null);
check("parseAircraft: missing fields stay unknown, not zero", unknown.altLabel === "Alt unknown" && unknown.altFt === null && unknown.speedKt === null && Number.isNaN(unknown.lat), unknown);
check("parseAircraft: callsign falls back to registration then hex", F.parseAircraft({ r: "n123ab", hex: "x" }, null).callsign === "N123AB" && F.parseAircraft({ hex: "a1b2c3" }, null).callsign === "A1B2C3");
const fromOrigin = F.parseAircraft({ hex: "a", lat: LHR.lat, lon: LHR.lon, dst: null }, JFK);
check("parseAircraft: missing dst is measured from the origin", near(fromOrigin.distNm, jfkLhr, 1e-6), fromOrigin.distNm);
check("parseAircraft: no origin and no dst leaves distance NaN", Number.isNaN(F.parseAircraft({ hex: "a", lat: 1, lon: 1 }, null).distNm));
const hostile = F.parseAircraft({ hex: "a", flight: "<img src=x>", desc: "<b>A330</b>", squawk: "7700<" }, null);
check("parseAircraft: hostile strings are neutralised", !/[<>&]/.test(JSON.stringify([hostile.callsign, hostile.type, hostile.squawk])), hostile);

check("parseAirport: missing coordinates give null", F.parseAirport({ iata_code: "JFK" }) === null && F.parseAirport(null) === null);
const ap = F.parseAirport({ icao_code: "egll", name: "Heathrow", latitude: "51.47", longitude: "-0.45" });
check("parseAirport: falls back to ICAO code", ap.code === "EGLL" && ap.lat === 51.47, ap);
check("parseAirport: no code at all reads ???", F.parseAirport({ latitude: 1, longitude: 1 }).code === "???");

const routeJson = JSON.stringify({ response: { flightroute: { airline: { name: "United" },
  origin: { iata_code: "JFK", latitude: JFK.lat, longitude: JFK.lon }, destination: { iata_code: "LHR", latitude: LHR.lat, longitude: LHR.lon } } } });
const route = F.parseRoute(routeJson, 65536);
check("parseRoute: parses origin, destination and airline", route.origin.code === "JFK" && route.destination.code === "LHR" && route.airline === "United", route);
check("parseRoute: no route on file throws", throws(() => F.parseRoute(JSON.stringify({ response: "unknown callsign" }), 65536)));
check("parseRoute: an airport without coordinates throws", throws(() => F.parseRoute(JSON.stringify({ response: { flightroute: { origin: { iata_code: "JFK" }, destination: route.destination } } }), 65536)));

check("routeProgress: 0 over the origin", near(F.routeProgress({ lat: JFK.lat, lon: JFK.lon }, route).fraction, 0, 1e-9));
check("routeProgress: 1 over the destination", near(F.routeProgress({ lat: LHR.lat, lon: LHR.lon }, route).fraction, 1, 1e-9));
const detour = F.routeProgress({ lat: 60, lon: -40 }, route);
check("routeProgress: a detour stays within 0..1", detour.valid && detour.fraction > 0 && detour.fraction < 1, detour);
check("routeProgress: no position is not valid", !F.routeProgress({ lat: NaN, lon: 0 }, route).valid && !F.routeProgress(null, route).valid);
const tiny = { origin: { lat: 0, lon: 0 }, destination: { lat: 0, lon: 0.001 } };
check("routeProgress: a sub-mile route is not valid", !F.routeProgress({ lat: 0, lon: 0 }, tiny).valid);

const cmd = F.cappedCurl("https://api.adsbdb.com/v0/callsign/UAL1", 1000, 10, ["-H", "Accept: application/json"]);
check("cappedCurl: caps at cap+1 bytes", cmd.indexOf("1001") > 0, cmd);
check("cappedCurl: https only and no redirects", cmd.indexOf("=https") > 0 && !cmd.some((a) => /^-[A-Za-z]*L/.test(a) || /^--location/.test(a)), cmd);
check("cappedCurl: url is passed after --", cmd[cmd.length - 2] === "--" && cmd[cmd.length - 1] === "https://api.adsbdb.com/v0/callsign/UAL1");
check("cappedCurl: outer timeout exceeds curl's", cmd[3] === "15" && cmd[cmd.indexOf("--max-time") + 1] === "10", cmd);
const zero = F.cappedCurl("https://api.adsbdb.com/x", 10, 0);
check("cappedCurl: a zero budget still has a deadline", zero[zero.indexOf("--max-time") + 1] === "1" && zero[3] === "6", zero);
check("cappedCurl: refused origin runs nothing", JSON.stringify(F.cappedCurl("https://evil.example/", 10, 5)) === JSON.stringify(["sh", "-c", "exit 1"]));

check("parseCappedJson: blank body throws", throws(() => F.parseCappedJson("  ", 100)));
check("parseCappedJson: oversized body throws", throws(() => F.parseCappedJson('{"a":"' + "x".repeat(200) + '"}', 100)));
check("parseCappedJson: valid body parses", F.parseCappedJson('{"a":1}', 100).a === 1);

const listJson = JSON.stringify({ ac: [{ hex: "far", dst: 9 }, { hex: "none" }, { hex: "near", dst: 1 }, { hex: "mid", dst: 4 }] });
const list = F.parseAircraftList(listJson, 1 << 20, 2000, null);
check("parseAircraftList: sorted by distance, unknown last", list.map((a) => a.hex).join(",") === "NEAR,MID,FAR,NONE", list.map((a) => a.hex));
check("parseAircraftList: clamps the element count", F.parseAircraftList(listJson, 1 << 20, 2, null).length === 2);
check("parseAircraftList: missing ac is an empty list", F.parseAircraftList("{}", 100, 10, null).length === 0);

check("criterionLabel: unknown reads Closest", F.criterionLabel("bogus") === "Closest" && F.criterionLabel("fastest") === "Fastest");
const fleet = [{ hex: "a", altFt: 3000, speedKt: 200 }, { hex: "b", altFt: null, speedKt: 450 }, { hex: "c", altFt: 39000, speedKt: null }];
const pick = (c) => F.pickAircraft(fleet, c);
check("pickAircraft: closest is the first", pick("closest").aircraft.hex === "a");
check("pickAircraft: lowest and highest skip unknown altitude", pick("lowest").aircraft.hex === "a" && pick("highest").aircraft.hex === "c");
check("pickAircraft: fastest and slowest skip unknown speed", pick("fastest").aircraft.hex === "b" && pick("slowest").aircraft.hex === "a");
const noAlt = F.pickAircraft([{ hex: "x", altFt: null, speedKt: 1 }], "highest");
check("pickAircraft: no candidates falls back to the closest", (noAlt.aircraft || {}).hex === "x" && noAlt.fellBack === true);
check("pickAircraft: empty list has no aircraft", F.pickAircraft([], "closest").aircraft === null);
check("pickAircraft: does not reorder the input", fleet.map((a) => a.hex).join("") === "abc");

console.log(failed === 0 ? "\nall logic checks passed" : "\n" + failed + " logic check(s) failed");
process.exit(failed === 0 ? 0 : 1);
