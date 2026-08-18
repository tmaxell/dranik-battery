#!/bin/bash
# Removes dranikd, and makes sure the charge gate is open before it goes.
#
# The order matters more than anything else here. The gate outlives the process
# that closed it, so deleting the daemon while the gate is shut would leave a
# machine that refuses to charge with nothing installed to fix it. So: stop the
# daemon (it opens the gate on SIGTERM), verify the gate really is open, and
# only then remove the files.
set -uo pipefail

LABEL="com.dranik.battery"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRANIK="/usr/local/bin/dranik"
[[ -x "$DRANIK" ]] || DRANIK="${REPO}/.build/release/dranik"

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
