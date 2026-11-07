#!/bin/bash
# Unit- und UI-Tests im eigenen Test-Simulator gegen das Test-Backend.
#   FIND_ENV=<pfad>/test-accounts.env tools/run-tests.sh [-only-testing:HomeFindTests]
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${HOMEFIND_DERIVED:-$HOME/Library/Caches/homefind-build}"
UDID="${SIM_UDID:-$(cat .sim-udid)}"
set -a; source "${FIND_ENV:?FIND_ENV fehlt}"; set +a
export TEST_RUNNER_HF_TEST_SERVER="$FIND_SERVER"
for who in MIA LEO IDA; do
  for f in KEY ID EMAIL PASSWORD; do v="FIND_${who}_${f}"; export "TEST_RUNNER_HF_TEST_${who}_${f}=${!v}"; done
done
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl location "$UDID" set 52.5200,13.4050
xcrun simctl privacy "$UDID" grant location-always org.homeroll.homefind 2>/dev/null || true
xcodegen generate -q
xcodebuild -project HomeFind.xcodeproj -scheme HomeFind -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$DERIVED/tests-$(date +%s).xcresult" test "$@" 2>&1 \
  | grep -E "Test Case|error:|Executed|TEST (SUCCEEDED|FAILED)|XCTAssert|failed" || true
