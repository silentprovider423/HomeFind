#!/bin/bash
# Baut HomeFind und startet es im eigenen Test-Simulator, angemeldet per Schlüssel aus der env-Datei (kein Passwort-Tippen).
#   FIND_ENV=<pfad>/test-accounts.env ./sim-run.sh            (UDID aus .sim-udid oder SIM_UDID)
# Standort wird simuliert (Berlin-Mitte), nie ein echter Standort.
set -euo pipefail
cd "$(dirname "$0")"
DERIVED="${HOMEFIND_DERIVED:-$HOME/Library/Caches/homefind-build}"
UDID="${SIM_UDID:-$(cat .sim-udid)}"
set -a; source "${FIND_ENV:?FIND_ENV fehlt}"; set +a
xcodegen generate -q
xcodebuild -project HomeFind.xcodeproj -scheme HomeFind -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" -quiet build 2>&1 | grep -E "error:" || true
APP="$DERIVED"/Build/Products/Debug-iphonesimulator/HomeFind.app
test -d "$APP"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl location "$UDID" set 52.5200,13.4050
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant location-always org.homeroll.homefind || true
SIMCTL_CHILD_FIND_SERVER="$FIND_SERVER" SIMCTL_CHILD_FIND_TOKEN="$FIND_MIA_KEY" SIMCTL_CHILD_FIND_SKIP_ONBOARDING=1 \
  xcrun simctl launch --terminate-running-process "$UDID" org.homeroll.homefind >/dev/null
echo "gestartet auf $UDID"
