#!/bin/bash
# Screenshots für docs/screenshots – nur Demokonten, erfundene Positionen (Berlin-Mitte).
#   FIND_ENV=<pfad>/test-accounts.env tools/screenshots.sh   (App vorher mit ./sim-run.sh installiert)
set -euo pipefail
cd "$(dirname "$0")/.."
UDID="${SIM_UDID:-$(cat .sim-udid)}"
set -a; source "${FIND_ENV:?FIND_ENV fehlt}"; set +a
tools/demo-state.sh all >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl location "$UDID" set 52.5200,13.4050
shot() { # name start
  SIMCTL_CHILD_FIND_SERVER="$FIND_SERVER" SIMCTL_CHILD_FIND_TOKEN="$FIND_MIA_KEY" SIMCTL_CHILD_FIND_SKIP_ONBOARDING=1 \
  SIMCTL_CHILD_FIND_START="$2" xcrun simctl launch --terminate-running-process "$UDID" org.homeroll.homefind >/dev/null
  sleep "${WAIT:-12}"
  xcrun simctl io "$UDID" screenshot "docs/screenshots/$1.png" >/dev/null 2>&1
  sips -Z 1200 "docs/screenshots/$1.png" >/dev/null
  echo "docs/screenshots/$1.png"
}
shot 1-people ""
shot 2-person "person:Leo"
shot 3-share "share"
shot 4-devices "devices"
shot 5-privacy "privacy,large"
xcrun simctl status_bar "$UDID" clear
