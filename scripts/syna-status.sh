#!/bin/bash
# Show what fprintd thinks is enrolled next to what is actually on the sensor.
#
#   ./scripts/syna-status.sh            # host side only, no root, no sensor access
#   sudo ./scripts/syna-status.sh --deep  # + enumerate the sensor's on-flash DB2
#
# Why this exists: fprintd's records (/var/lib/fprint) and the sensor's own flash (DB2)
# are separate stores and they DESYNC. `fprintd-delete` clears the host side only; the
# templates stay in sensor flash forever. See docs/RESET.md.
set -u
source "$(dirname "$0")/common.sh"

DEEP=0
[ "${1:-}" = "--deep" ] && DEEP=1

echo "=== sensor ==="
if sensor_present; then
    echo "  $SENSOR_VID:$SENSOR_PID present on the USB bus"
else
    echo "  $SENSOR_VID:$SENSOR_PID NOT found — check 'lsusb'"
fi

echo
echo "=== host side (fprintd) ==="
user="${SUDO_USER:-${USER:-root}}"
if command -v fprintd-list >/dev/null 2>&1; then
    fprintd-list "$user" 2>&1 | sed 's/^/  /'
else
    echo "  fprintd-list not installed"
fi
printf '  /var/lib/fprint: '
if [ -d /var/lib/fprint ]; then
    n=$(find /var/lib/fprint -type f 2>/dev/null | wc -l)
    echo "$n template file(s)"
    find /var/lib/fprint -type f 2>/dev/null | sed 's|^|    |'
else
    echo "absent"
fi

if [ "$DEEP" -eq 0 ]; then
    echo
    echo "Sensor-side templates not read. Re-run as: sudo $0 --deep"
    exit 0
fi

echo
echo "=== sensor side (on-flash DB2) ==="
require_root --deep
require_cli
log="$(new_log status)"
release_from_fprintd
wake_sensor
printf 'y\ns\n' | timeout 70 "$CLI" "$STORE" -vv -t -P"$SENSOR_PID" > "$log" 2>&1 || true

# 9f = GET_OBJECT_LIST; the byte after it is the list type. 02 = top-level templates,
# 03 = children of a given user. Only children of the common-property user are loaded
# into the matcher — anything under 02 that is not also under 03 is an orphan.
top=$(grep -ciE 'TX.*\b9f *02' "$log" 2>/dev/null || true)
kids=$(grep -ciE 'TX.*\b9f *03' "$log" 2>/dev/null || true)
users=$(grep -oiE 'NumCurrentUsers[^0-9]*([0-9]+)' "$log" 2>/dev/null | tail -1 || true)

echo "  ${users:-NumCurrentUsers: unknown}"
echo "  GET_OBJECT_LIST(top-level templates) frames: ${top:-0}"
echo "  GET_OBJECT_LIST(children-of-user)    frames: ${kids:-0}"
echo "  full trace: $log"
echo
echo "  Reading raw frame counts is a coarse proxy, not an exact template count —"
echo "  grep the trace against work/re-notes/template-load-chain.md to decode it."
echo "  If the host side above shows fewer fingers than the sensor is holding, that is"
echo "  the known desync: only a BIOS fingerprint reset clears sensor flash (docs/RESET.md)."
