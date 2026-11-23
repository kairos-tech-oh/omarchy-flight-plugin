#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

status=0
note() { printf '\n=== %s ===\n' "$1"; }

note "FlightLogic under node"
if command -v node >/dev/null 2>&1; then
  node tools/check-logic.js || status=1
else
  echo "  skipped: node not installed"
fi

note "FlightLogic under Qt's V4 engine"
qml_bin=""
for candidate in /usr/lib/qt6/bin/qml "$(command -v qml 2>/dev/null)"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && qml_bin="$candidate" && break
done
if [ -n "$qml_bin" ]; then
  QT_QPA_PLATFORM=offscreen "$qml_bin" tools/check-qml-engine.qml
  code=$?
  if [ "$code" -eq 0 ]; then echo "  all V4 checks passed"
  else echo "  FAILED at check $code (see tools/check-qml-engine.qml)"; status=1; fi
else
  echo "  skipped: no qml runner found"
fi

note "shell conventions"
tools/check-conventions.sh || status=1

note "result"
if [ "$status" -eq 0 ]; then echo "everything passed"; else echo "one or more checks failed"; fi
exit "$status"
