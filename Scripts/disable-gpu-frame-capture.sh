#!/bin/bash
#
# Disables Xcode's Metal GPU Frame Capture and GPU validation in the scheme.
#
# XcodeGen has no option for these keys, so they have to be patched back in
# after every `xcodegen generate` (wired up via options.postGenCommand),
# the same way Scripts/disable-queue-debugging.sh does.
#
# Why: with GPU Frame Capture on (Xcode's default is "Automatically Enabled"),
# Xcode injects GPUToolsCapture via DYLD_INSERT_LIBRARIES and turns on the Metal
# interposer (GPUTOOLS_LOAD_GTMTLCAPTURE=1, METAL_LOAD_INTERPOSER=1,
# MTL_DEBUG_LAYER=1). SwiftUI renders through RenderBox/Metal, and committing a
# CoreAnimation transaction can then deadlock inside that capture layer:
#
#   CA::Transaction::commit()
#    -> RB::SharedSurfaceGroup::render_updates()
#      -> -[CaptureMTLCommandBuffer commitAndWaitUntilSubmitted]
#        -> _dispatch_sync_f_slow -> __DISPATCH_WAIT_FOR_QUEUE__ -> kevent_id
#
# The main thread never returns, so the whole UI freezes at 0% CPU — clicks are
# accepted but nothing ever redraws. The same build launched outside Xcode has no
# GPUTools libraries loaded and runs fine, which is how this was pinned down.
#
# Verified by launching from Xcode and inspecting the app process: GPUToolsCapture
# is gone from DYLD_INSERT_LIBRARIES, and GPUTOOLS_LOAD_GTMTLCAPTURE,
# METAL_LOAD_INTERPOSER and MTL_DEBUG_LAYER are no longer set.
#
# Note when re-checking this: Xcode keeps the scheme in memory, so patching the file
# while Xcode is open does not affect the next Run. Quit and reopen Xcode first, or
# the check looks like a failure:
#   ps -Eww -p <pid> | tr ' ' '\n' | grep DYLD_INSERT_LIBRARIES
set -euo pipefail

ATTRS=(
    'enableGPUFrameCaptureMode = "3"'
    'enableGPUValidationMode = "1"'
)
SCHEME="$(cd "$(dirname "$0")/.." && pwd)/Conclawd.xcodeproj/xcshareddata/xcschemes/Conclawd.xcscheme"

if [ ! -f "$SCHEME" ]; then
    echo "warning: scheme not found at $SCHEME - skipping" >&2
    exit 0
fi

for attr in "${ATTRS[@]}"; do
    key="${attr%% *}"
    if grep -q "$key" "$SCHEME"; then
        continue
    fi
    # Insert as the first attribute of the <LaunchAction ...> tag. The tag is
    # emitted with one attribute per line, so its opening line has no '>'.
    /usr/bin/awk -v attr="$attr" '
        { print }
        !done && /<LaunchAction/ && !/>/ {
            match($0, /^[ \t]*/)
            print substr($0, 1, RLENGTH) "   " attr
            done = 1
        }
    ' "$SCHEME" > "$SCHEME.tmp"

    if grep -q "$key" "$SCHEME.tmp"; then
        mv "$SCHEME.tmp" "$SCHEME"
        echo "Patched scheme: $attr"
    else
        rm -f "$SCHEME.tmp"
        echo "error: could not find <LaunchAction> opening tag in $SCHEME" >&2
        exit 1
    fi
done
