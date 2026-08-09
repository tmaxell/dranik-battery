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

# Probe before installing anything. A machine whose charge gate this build does
# not recognise has nothing to gain from a daemon that will refuse to act.
if ! "${BUILD}/dranik" status | grep -q "Charge gate .*key"; then
    echo "no usable charge gate on this machine — not installing" >&2
    "${BUILD}/dranik" status | sed -n '/Charge control/,$p' >&2
    exit 1
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
