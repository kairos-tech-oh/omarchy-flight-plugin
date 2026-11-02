#!/usr/bin/env bash
# Check the plugin's QML against the Omarchy shell's current conventions.
#
#   tools/check-conventions.sh
#
# These mirror rules upstream enforces on first-party QML and asks third-party
# plugins to follow (docs/omarchy-shell.md, agents/skills/{shell-dev,motion}.md).
# Plain grep/awk, so they run anywhere, with or without an Omarchy install.
#   - Qt 6.12 ships its own `Color` type in QtQuick, which shadows the palette
#     singleton: every palette reference is `Commons.Color`.
#   - Every animation duration goes through Style.duration(), which is 0 once
#     `omarchy toggle animations` has turned motion off.
#   - A Text whose text is not a bare string literal declares textFormat, so
#     Text.AutoText can never promote outside data to rich text.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

mapfile -t files < <(find . -name .git -prune -o -name '*.qml' -print | sort)
[ "${#files[@]}" -gt 0 ] || { echo "  no QML files"; exit 0; }

out=""
bare_color=$(grep -nE '(^|[^.A-Za-z_])Color\.[a-z]' "${files[@]}" || true)
[ -n "$bare_color" ] && out+="unqualified Color (use Commons.Color):"$'\n'"$bare_color"$'\n'
bare_duration=$(grep -nE '(^|[{;])[[:space:]]*duration:[[:space:]]*[0-9]' "${files[@]}" || true)
[ -n "$bare_duration" ] && out+="bare animation duration (use Style.duration()):"$'\n'"$bare_duration"$'\n'
auto_text=$(awk '
  FNR == 1 { d = 0 }
  /^[ \t]*Text[ \t]*\{/ && !d { d = 1; depth = 0; start = FNR; fmt = 0; dyn = 0 }
  d {
    l = $0; depth += gsub(/\{/, "{", l) - gsub(/\}/, "}", l)
    if (depth == 1 && $0 ~ /^[ \t]*textFormat[ \t]*:/) fmt = 1
    if (depth == 1 && $0 ~ /^[ \t]*text[ \t]*:/ && $0 !~ /^[ \t]*text[ \t]*:[ \t]*"[^"]*"[ \t]*$/) dyn = 1
    if (depth <= 0) { if (dyn && !fmt) print FILENAME ":" start; d = 0 }
  }' "${files[@]}")
[ -n "$auto_text" ] && out+="Text with a dynamic binding and no textFormat:"$'\n'"$auto_text"$'\n'

if [ -z "$out" ]; then
  echo "  palette, motion and textFormat conventions hold"
  exit 0
fi
printf '%s' "$out"
exit 1
