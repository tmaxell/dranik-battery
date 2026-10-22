#!/bin/bash
# Installs dranikd as a system LaunchDaemon.
#
# Deliberately does not start it charging-limited out of the box: it writes a
# default configuration only if none exists, so re-running this never overwrites
# a limit someone has set.
set -euo pipefail

LABEL="com.dranik.battery"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LIBEXEC="/usr/local/libexec"
BINDIR="/usr/local/bin"
SUPPORT="/Library/Application Support/dranik"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${REPO}/.build/release"

if [[ $EUID -ne 0 ]]; then
    echo "install.sh must run as root: sudo $0" >&2
    exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Apple Silicon only — this machine is $(uname -m)" >&2
    exit 1
fi

if [[ ! -x "${BUILD}/dranikd" ]]; then
    echo "build first: make build" >&2
    exit 1
fi

# Probe before installing anything, and tell two failures apart.
#
# An unreadable SMC is fatal: the daemon cannot even start without a connection
# to it, so there would be nothing to install.
#
# No recognised charge gate used to be fatal too, on the grounds that such a
# machine "has nothing to gain from a daemon that will refuse to act". That
# stopped being true: the daemon now stays up and keeps saying why nothing is
# being limited, in the CLI and in the menu bar. Someone whose firmware took the
# key away needs exactly that answer — and refusing to install denies them the
# one thing that would give it.
STATUS="$("${BUILD}/dranik" status 2>&1 || true)"

if echo "${STATUS}" | grep -q "SMC .*unavailable"; then
    echo "cannot read the SMC on this machine — not installing" >&2
    echo "${STATUS}" | sed -n '/Charge control/,$p' >&2
    exit 1
fi

# Either mechanism will do. A machine whose firmware took `CHTE` away may well
# have the firmware corridor instead — that is what the mBoot-20457 update did —
# and warning about a missing gate there would be alarming and wrong.
if ! echo "${STATUS}" | grep -q "Charge gate .*key" \
   && ! echo "${STATUS}" | grep -qE "Firmware limit +bf"; then
    echo "WARNING: nothing on this machine that this build can limit charging with." >&2
    echo "         Installing anyway: the daemon will report why nothing is" >&2
    echo "         being limited, but it will NOT limit charging." >&2
    echo "${STATUS}" | sed -n '/Charge control/,$p' >&2
fi

echo "==> stopping any running instance"
launchctl bootout "system/${LABEL}" 2>/dev/null || true

echo "==> installing binaries"
install -d -o root -g wheel -m 755 "${LIBEXEC}" "${BINDIR}"
install -o root -g wheel -m 755 "${BUILD}/dranikd" "${LIBEXEC}/dranikd"
install -o root -g wheel -m 755 "${BUILD}/dranik" "${BINDIR}/dranik"

echo "==> preparing ${SUPPORT}"
install -d -o root -g wheel -m 755 "${SUPPORT}"
if [[ ! -f "${SUPPORT}/config.json" ]]; then
    cat > "${SUPPORT}/config.json" <<'JSON'
{
  "upperLimit" : 80,
  "lowerLimit" : 75,
  "thermalCutoff" : 40,
  "sleepPolicy" : "holdLimit",
  "preventIdleSleepWhileCharging" : false
}
JSON
    chown root:wheel "${SUPPORT}/config.json"
    chmod 644 "${SUPPORT}/config.json"
    echo "    wrote a default configuration (limit 80%)"
else
    echo "    keeping the existing configuration"
fi

echo "==> installing ${PLIST}"
install -o root -g wheel -m 644 "${REPO}/scripts/${LABEL}.plist" "${PLIST}"

echo "==> starting"
launchctl bootstrap system "${PLIST}"

sleep 2
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo
    echo "running. Check on it with:"
    echo "    dranik status"
    echo "    sudo log stream --predicate 'subsystem == \"com.dranik.battery\"'"
    echo
    echo "To stop and fully remove it, including reopening the charge gate:"
    echo "    sudo ${REPO}/scripts/uninstall.sh"
else
    echo "failed to start — see /var/log/dranikd.log" >&2
    exit 1
fi
