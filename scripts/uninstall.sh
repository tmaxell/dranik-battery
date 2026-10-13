#!/bin/bash
# Removes dranikd, and makes sure nothing is left limiting charging before it goes.
#
# The order matters more than anything else here, and there are two things that
# outlive the process:
#
#   the charge gate       — closed, it stops the battery charging. The daemon
#                           opens it on SIGTERM, so stopping it is enough; this
#                           script verifies rather than assumes.
#   the firmware corridor — kept by the hardware on purpose, so stopping the
#                           daemon does NOT clear it. It has to be cleared
#                           explicitly, and only `dranikd` can write to the SMC.
#
# Either one left behind would leave a machine managing its own charging with
# nothing installed to change it. So: stop the daemon, clear the corridor, verify
# both, and only then remove the files.
set -uo pipefail

LABEL="com.dranik.battery"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRANIK="/usr/local/bin/dranik"
[[ -x "$DRANIK" ]] || DRANIK="${REPO}/.build/release/dranik"
DRANIKD="/usr/local/libexec/dranikd"
[[ -x "$DRANIKD" ]] || DRANIKD="${REPO}/.build/release/dranikd"

if [[ $EUID -ne 0 ]]; then
    echo "uninstall.sh must run as root: sudo $0" >&2
    exit 1
fi

echo "==> stopping the daemon (it opens the gate on the way out)"
launchctl bootout "system/${LABEL}" 2>/dev/null || true
# The hardware takes about seven seconds to act on a gate write.
sleep 10

if [[ -x "$DRANIK" ]]; then
    echo "==> checking the charge gate"
    GATE="$("$DRANIK" smc CHTE 2>/dev/null | awk -F'\t' '{print $7}')"
    if [[ -n "$GATE" && "$GATE" != "00000000" ]]; then
        echo
        echo "    WARNING: CHTE reads ${GATE}, which is not the open value." >&2
        echo "    Not removing anything. Reboot — the SMC returns to its" >&2
        echo "    defaults — and run this again." >&2
        exit 2
    fi
    echo "    gate is open (CHTE=${GATE:-unreadable})"
fi

# After the bootout, so the daemon cannot put the corridor straight back.
if [[ -x "$DRANIKD" ]]; then
    echo "==> clearing the firmware charge corridor"
    if ! "$DRANIKD" --clear-firmware-limit; then
        echo
        echo "    WARNING: the firmware is still holding a charge corridor." >&2
        echo "    Not removing anything: this Mac would go on limiting its own" >&2
        echo "    charging with nothing installed to stop it." >&2
        echo "    Look at it with:  dranik status" >&2
        exit 3
    fi
fi

if [[ -x "$DRANIK" ]]; then
    # Independent of what the clear reported, by the same rule as the gate check.
    ACTIVATION="$("$DRANIK" smc bfF0 2>/dev/null | awk -F'\t' '{print $7}')"
    if [[ -n "$ACTIVATION" && "$ACTIVATION" != "00" ]]; then
        echo
        echo "    WARNING: bfF0 reads ${ACTIVATION}, so a firmware corridor is" >&2
        echo "    still active. Not removing anything." >&2
        exit 3
    fi
fi

echo "==> removing files"
rm -f "${PLIST}"
rm -f /usr/local/libexec/dranikd
rm -f /var/run/dranikd.pid
rm -f "/Library/Application Support/dranik/state.json"

echo
echo "removed. Left in place on purpose:"
echo "    /Library/Application Support/dranik/config.json   (your limit)"
echo "    /usr/local/bin/dranik                             (the read-only CLI)"
echo "    /var/log/dranikd.log"
