#!/bin/bash
# Install the suspend/resume hook that stops the fingerprint sensor wedging.
#
#   sudo ./setup-sleep-hook.sh          # install
#   sudo ./setup-sleep-hook.sh --undo   # remove again
#
# See sleep-hook/fingerprint-reset for the full explanation of what goes wrong.
# Short version: Omarchy locks the screen inside the suspend-delay window, the
# lock screen starts a fingerprint auth, and we suspend with the sensor open and
# mid-verify. On resume the sensor and the host disagree about the TLS session
# and the reader stops responding -- icon on the lock screen, nothing happens.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "needs root: sudo $0 $*" >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This MUST be /usr/lib, even though that is normally package territory.
# systemd-sleep compiles in exactly one hook directory and does not read /etc:
#     $ strings /usr/lib/systemd/systemd-sleep | grep system-sleep
#     /usr/lib/systemd/system-sleep
# A hook dropped in /etc/systemd/system-sleep/ is silently never executed --
# no error, no log line, it simply does nothing. Ask me how I know.
DEST=/usr/lib/systemd/system-sleep/fingerprint-reset
LEGACY=/etc/systemd/system-sleep/fingerprint-reset

if [ "${1:-}" = "--undo" ]; then
    rm -f "$DEST" && echo "removed $DEST"
    [ -e "$LEGACY" ] && rm -f "$LEGACY" && echo "removed $LEGACY"
    exit 0
fi

# Clean up the version that never ran.
if [ -e "$LEGACY" ]; then
    rm -f "$LEGACY"
    echo "removed $LEGACY (systemd never read that directory)"
fi

command -v usbreset >/dev/null || {
    echo "usbreset not found -- install it with: pacman -S usbutils" >&2
    exit 1
}

install -Dm755 "$DIR/sleep-hook/fingerprint-reset" "$DEST"
echo "installed $DEST"

# No daemon-reload needed: systemd-sleep scans the directory at suspend time.
echo
echo "Confirm it ran after a real suspend:"
echo "    journalctl -t fingerprint-reset"
echo
echo "Test it without a real suspend:"
echo "    sudo $DEST pre  suspend"
echo "    sudo $DEST post suspend"
echo "    fprintd-verify \$SUDO_USER"
