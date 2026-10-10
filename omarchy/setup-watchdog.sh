#!/bin/bash
# Install the watchdog that recovers the fingerprint sensor when it wedges.
#
#   sudo ./setup-watchdog.sh          # install and start
#   sudo ./setup-watchdog.sh --undo   # stop and remove again
#
# See watchdog/fingerprint-watchdog for the full explanation. Short version, two
# failures, each recognised from fprintd's journal:
#
#   - the sensor wedges ("The device is still busy with another operation") and
#     stays dead until the daemon is stopped and the USB device reset -- the same
#     pair of steps the suspend hook does;
#   - after a resume, fprintd meets the sensor's stale TLS session ("Sensor is in
#     TLS session but host is not") and that daemon never arms the sensor again
#     -- fixed by replacing the daemon.
#
# Either way the sensor is working again by the time anyone tries it, with
# nothing to press.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "needs root: sudo $0 $*" >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT_DEST=/usr/local/bin/fingerprint-watchdog
UNIT_NAME=omarchy-fingerprint-watchdog.service
UNIT_DEST=/etc/systemd/system/$UNIT_NAME

if [ "${1:-}" = "--undo" ]; then
    systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
    rm -f "$UNIT_DEST" && echo "removed $UNIT_DEST"
    rm -f "$SCRIPT_DEST" && echo "removed $SCRIPT_DEST"
    systemctl daemon-reload
    echo "watchdog removed"
    exit 0
fi

command -v usbreset >/dev/null || {
    echo "usbreset not found -- install it with: pacman -S usbutils" >&2
    exit 1
}

install -Dm755 "$DIR/watchdog/fingerprint-watchdog" "$SCRIPT_DEST"
echo "installed $SCRIPT_DEST"

install -Dm644 "$DIR/watchdog/$UNIT_NAME" "$UNIT_DEST"
echo "installed $UNIT_DEST"

systemctl daemon-reload
systemctl enable "$UNIT_NAME"
# restart, not start: on a re-install the old script is still the one running.
systemctl restart "$UNIT_NAME"
echo "enabled and (re)started $UNIT_NAME"

echo
echo "Confirm it is watching:"
echo "    journalctl -t fingerprint-watchdog -n 5"
echo
echo "It should print a line like:"
echo "    watching fprintd (sensor 06cb:00ff, wedge cooldown 90s, arm grace 3s)"
echo
echo "Nothing more to do -- it fires on its own the next time the sensor dies,"
echo "and logs what it did to the same journal tag."
