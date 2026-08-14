#!/bin/bash
#
# Disables Xcode's "Queue Debugging -> Enable backtrace recording" in the scheme.
#
# XcodeGen 2.45.3 has no option for this key, so it has to be patched back in
# after every `xcodegen generate` (wired up via options.postGenCommand).
#
# The attribute MUST be queueDebuggingEnabled. Do not use
# queueDebuggingEnableBacktraceRecording: per IDEFoundation's
# -[IDELaunchSchemeAction setQueueDebuggingEnableBacktraceRecordingFromUTF8String:
# fromXMLUnarchiver:], that setter early-returns on a falsy value and never
# touches _queueDebuggingState, so `= "No"` is a silent no-op and Xcode strips
# the attribute on its next scheme save.
#
# Why: with backtrace recording on, Xcode injects libBacktraceRecording.dylib.
# Its pthread_atfork prepare handler takes a global os_unfair_lock that the
# thread-creation and GCD enqueue/dequeue hooks also take. Conclawd forks a PTY
# for every terminal spawn (SwiftTerm forkpty), so the fork deadlocks against
# those hooks and the whole app hangs inside fork() on the main thread.

set -euo pipefail

ATTR='queueDebuggingEnabled = "No"'
SCHEME="$(cd "$(dirname "$0")/.." && pwd)/Conclawd.xcodeproj/xcshareddata/xcschemes/Conclawd.xcscheme"

if [ ! -f "$SCHEME" ]; then
    echo "warning: scheme not found at $SCHEME - skipping" >&2
    exit 0
fi

if grep -q 'queueDebuggingEnabled' "$SCHEME"; then
    exit 0
fi

# Insert the attribute as the first attribute of the <LaunchAction ...> tag.
# The tag is emitted with one attribute per line, so the opening line has no '>'.
/usr/bin/awk -v attr="$ATTR" '
    { print }
    !done && /<LaunchAction/ && !/>/ {
        match($0, /^[ \t]*/)
        print substr($0, 1, RLENGTH) "   " attr
        done = 1
    }
' "$SCHEME" > "$SCHEME.tmp"

if grep -q 'queueDebuggingEnabled' "$SCHEME.tmp"; then
    mv "$SCHEME.tmp" "$SCHEME"
    echo "Patched scheme: disabled Queue Debugging backtrace recording"
else
    rm -f "$SCHEME.tmp"
    echo "error: could not find <LaunchAction> opening tag in $SCHEME" >&2
    exit 1
fi
