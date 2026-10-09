#!/bin/bash
# Install the watchdog that recovers the fingerprint sensor when it wedges.
#
#   sudo ./setup-watchdog.sh          # install and start
#   sudo ./setup-watchdog.sh --undo   # stop and remove again
#
# See watchdog/fingerprint-watchdog for the full explanation. Short version: the
# sensor stops reading while idle -- the driver's "wait for finger" transfer
# expires about once a minute, and eventually one re-arm hits a sensor that has
# not finished the last operation ("The device is still busy with another
# operation"). From then on the reader is dead until the daemon is stopped and
# the USB device reset, which is the same pair of steps the suspend hook does.
#
# This watches fprintd's journal for that one line and does those two steps, so
# the sensor is already working again by the time anyone walks up to the machine.
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
systemctl enable --now "$UNIT_NAME"
echo "enabled and started $UNIT_NAME"

echo
echo "Confirm it is watching:"
echo "    journalctl -t fingerprint-watchdog -n 5"
echo
echo "It should print a line like:"
echo "    watching fprintd for \"still busy with another operation\" ..."
echo
echo "Nothing more to do -- it fires on its own the next time the sensor wedges,"
echo "and logs what it did to the same journal tag."
