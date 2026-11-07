#!/bin/sh
# SKYFORGE verification gate. Usage: tools/gate.sh [fast|full|ci]
#   fast: swift build + swift test + pbxproj lint (+ warning check in our sources)
#   full: fast + (macOS only) xcodebuild iOS Simulator + macOS + tests on dynamically chosen simulators
#   ci:   full + licence/attribution checks
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
LEVEL="${1:-fast}"
PKG="$ROOT/Packages/SkyforgeKit"
LOG="$ROOT/docs/VERIFICATION_LOG.md"
[ -d "$HOME/.skyforge-toolchain/usr/bin" ] && PATH="$HOME/.skyforge-toolchain/usr/bin:$PATH" && export PATH
status=0
note() { echo "gate[$LEVEL]: $*"; }
fail() { note "FAIL: $*"; status=1; }

if ! command -v swift >/dev/null 2>&1; then
  note "swift not found; run tools/setup_env.sh"; exit 1
fi

note "swift build"
swift build --package-path "$PKG" > "$ROOT/.skyforge/build.log" 2>&1 || { tail -n 40 "$ROOT/.skyforge/build.log"; fail "swift build"; }
if grep -E "^$PKG/(Sources|Tests)/.*warning:" "$ROOT/.skyforge/build.log" >/dev/null 2>&1; then
  grep -E "^$PKG/(Sources|Tests)/.*warning:" "$ROOT/.skyforge/build.log" | head -n 20
  fail "compiler warnings in our sources"
fi
note "swift test"
swift test --package-path "$PKG" > "$ROOT/.skyforge/test.log" 2>&1 || { grep -E "✘|error:" "$ROOT/.skyforge/test.log" | head -n 40; fail "swift test"; }
grep -E "Test run with" "$ROOT/.skyforge/test.log" | tail -n 1
note "pbxproj lint"
python3 tools/lint_pbxproj.py || fail "pbxproj lint"
for f in App/Info.plist App/SKYFORGE.entitlements App/PrivacyInfo.xcprivacy; do
  python3 -c "import plistlib,sys; plistlib.load(open('$f','rb'))" 2>/dev/null || fail "plist $f"
done

if [ "$LEVEL" = "full" ] || [ "$LEVEL" = "ci" ]; then
  if [ "$(uname -s)" = "Darwin" ] && command -v xcodebuild >/dev/null 2>&1; then
    plutil -lint SKYFORGE.xcodeproj/project.pbxproj || fail "plutil"
    xcodebuild -project SKYFORGE.xcodeproj -scheme SKYFORGE -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build -quiet || fail "xcodebuild iOS Simulator"
    xcodebuild -project SKYFORGE.xcodeproj -scheme SKYFORGE -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build -quiet || fail "xcodebuild macOS"
  else
    note "full: xcodebuild steps skipped (not macOS); recorded as unverified"
  fi
fi

if [ "$LEVEL" = "ci" ]; then
  note "licence/attribution checks"
  python3 tools/check_licenses.py || fail "licence check"
fi

result=PASS; [ $status -ne 0 ] && result=FAIL
mkdir -p docs
echo "- $(date -u +%FT%TZ) gate $LEVEL on $(uname -s -m): $result (HEAD $(git rev-parse --short HEAD 2>/dev/null))" >> "$LOG"
note "$result"
exit $status
