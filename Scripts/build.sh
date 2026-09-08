#!/bin/bash
# Builds Conclawd from the CLI into a project-local DerivedData directory.
#
# Xcode.app uses the shared ~/Library/Developer/Xcode/DerivedData location.
# Running `xcodebuild` there at the same time as a build in Xcode makes both
# processes contend for XCBuildData/build.db and one of them fails with
# "unable to attach DB: ... database is locked". Keeping CLI builds in
# build/DerivedData means the two never share a build database.
#
# A lock directory additionally prevents two CLI builds from overlapping.
#
# Usage:
#   Scripts/build.sh                      # Debug build
#   Scripts/build.sh Release              # Release build (unsigned; use release.sh to ship)
#   Scripts/build.sh Debug clean build    # override the xcodebuild actions
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Debug}"
shift || true
ACTIONS=("$@")
[[ ${#ACTIONS[@]} -eq 0 ]] && ACTIONS=(build)

DERIVED=build/DerivedData
LOCK="$DERIVED/.build.lock"

mkdir -p "$DERIVED"
if ! mkdir "$LOCK" 2>/dev/null; then
    OWNER=$(cat "$LOCK/pid" 2>/dev/null || echo "")
    if [[ -n "$OWNER" ]] && kill -0 "$OWNER" 2>/dev/null; then
        echo "error: another Scripts/build.sh is already building (pid $OWNER)." >&2
        echo "       Wait for it to finish, or kill it before retrying." >&2
        exit 1
    fi
    echo "==> Clearing stale build lock (owner pid ${OWNER:-unknown} is gone)"
    rm -rf "$LOCK"
    mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

echo "==> Building Conclawd ($CONFIGURATION) into $DERIVED"
xcodebuild -project Conclawd.xcodeproj -scheme Conclawd \
    -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED" \
    "${ACTIONS[@]}"

echo "==> Product: $DERIVED/Build/Products/$CONFIGURATION/Conclawd.app"
