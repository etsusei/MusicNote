#!/bin/zsh
# Exercise the real AppModel's observation/adoption path in a disposable library.
set -euo pipefail
ROOT="${0:A:h:h}"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
cd "$ROOT"
swift build --disable-sandbox --product Musicnote
BIN="$(swift build --disable-sandbox --show-bin-path)"
APP_SOURCES=("$ROOT"/Sources/MusicnoteApp/**/*.swift)
APP_SOURCES=("${(@)APP_SOURCES:#*/main.swift}")
# The app also needs practice mode's module and the Rubber Band stretcher under it (C++).
if [[ -f "$BIN/MusicnoteCore.o" ]]; then
  CORE_OBJECTS=("$BIN/MusicnoteCore.o" "$BIN/MusicnotePractice.o" "$BIN/RubberBand.o")
else
  CORE_OBJECTS=("$BIN"/MusicnoteCore.build/*.swift.o "$BIN"/MusicnotePractice.build/*.swift.o "$BIN"/RubberBand.build/**/*.o)
fi
RUBBERBAND_MAP=("$ROOT"/.build/**/GeneratedModuleMaps/RubberBand.modulemap(N) "$BIN"/RubberBand.build/module.modulemap(N))
xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path "$ROOT/.build/harmony-check-module-cache" \
  -target "$(uname -m)-apple-macosx27.0" -I "$BIN" -I "$BIN/Modules" \
  "$ROOT/Tests/MusicnoteAppChecks/HarmonyRefreshChecks.swift" \
  -Xcc -fmodule-map-file="${RUBBERBAND_MAP[1]}" \
  "${APP_SOURCES[@]}" "${CORE_OBJECTS[@]}" -lsqlite3 -lc++ -framework Accelerate \
  -o "$CHECK_DIR/HarmonyRefreshChecks"
MUSICNOTE_DATA_ROOT="$CHECK_DIR/library" "$CHECK_DIR/HarmonyRefreshChecks"
