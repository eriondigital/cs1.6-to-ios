#!/usr/bin/env bash
#
# Smoke test in the iOS Simulator (macOS only), run after `scripts/build.sh simulator`.
#
#   1. first launch, no game files     -> expect the "Game files needed" alert
#   2. placeholder game files          -> expect the engine to boot to the main menu
#   3. placeholder files + map + bots  -> expect a map to load with YaPB bots
#
# Screenshots, engine logs, the system log and crash reports end up in out/sim-test/.
# Valve's game data is never used here; see scripts/make_stub_data.py.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/out/simulator/Payload/CS16.app"
ART="$ROOT/out/sim-test"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
rm -rf "$ART"
mkdir -p "$ART"

read -r RUNTIME DEVTYPE < <(xcrun simctl list -j | python3 -c '
import json, sys
d = json.load(sys.stdin)
rts = [r for r in d["runtimes"] if r.get("isAvailable") and r.get("platform", "iOS") == "iOS" and "iOS" in r["name"]]
rt = rts[-1]
types = [t for t in rt.get("supportedDeviceTypes", d["devicetypes"]) if t["name"].startswith("iPhone")]
pick = next((t for t in types if "Pro Max" not in t["name"] and "Pro" in t["name"]), types[-1])
print(rt["identifier"], pick["identifier"])
')
echo "runtime: $RUNTIME"
echo "device:  $DEVTYPE"

UDID="$(xcrun simctl create cs16-smoke "$DEVTYPE" "$RUNTIME")"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant microphone "$BUNDLE_ID" || true
DOCS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Documents"
echo "documents: $DOCS"

shot() { xcrun simctl io "$UDID" screenshot "$ART/$1.png" >/dev/null 2>&1 || echo "screenshot $1 failed"; }
stop() { xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true; sleep 2; }
keep_log() { [ -f "$DOCS/engine.log" ] && cp "$DOCS/engine.log" "$ART/$1-engine.log"; ls -laR "$DOCS" > "$ART/$1-documents.txt" 2>&1 || true; }

echo "== 1. no game files"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 15
shot 1-no-game-files
keep_log 1
stop

echo "== 2. placeholder game files"
python3 "$ROOT/scripts/make_stub_data.py" "$DOCS"
echo "-dev 2" > "$DOCS/commandline.txt"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 30
shot 2-menu
keep_log 2
stop

echo "== 3. map with bots"
# the published extras.pk3 has no maps; borrow the training map from the build tree for this test only
mkdir -p "$DOCS/cstrike/maps"
unzip -o -j -q "$ROOT/out/simulator/cs16-install/cstrike/extras.pk3" maps/tr_1.bsp -d "$DOCS/cstrike/maps" || echo "could not extract tr_1.bsp"
echo "-dev 2 +maxplayers 6 +map tr_1" > "$DOCS/commandline.txt"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 50
shot 3-map
keep_log 3
stop

xcrun simctl spawn "$UDID" log show --last 15m --style compact --predicate 'process == "xash"' > "$ART/system.log" 2>&1 || true
find ~/Library/Logs/DiagnosticReports -name 'xash*' -mmin -30 -exec cp {} "$ART/" \; 2>/dev/null || true

xcrun simctl shutdown "$UDID" || true
xcrun simctl delete "$UDID" || true

echo "== results"
ls -la "$ART"
for f in "$ART"/*-engine.log; do
	[ -f "$f" ] || continue
	echo "---- $f (errors/warnings/bots)"
	grep -a -i -E "error|crash|fatal|signal|yapb|regamedll|connecting bot|loaded|renderer|ref_" "$f" | head -60
done
