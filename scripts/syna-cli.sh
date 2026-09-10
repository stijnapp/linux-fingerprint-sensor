#!/bin/bash
# Run as root:  sudo bash scripts/syna-cli.sh [usb_timeout_ms]
# Launches synaTudor's CLI with our HP v11.1 driver against the sensor.
set -u
source "$(dirname "$0")/common.sh"
require_root "$@"
require_cli
sensor_present || echo "WARNING: no $SENSOR_VID:$SENSOR_PID on the USB bus — open() will fail."

# Timestamped per-run log so an enroll trace isn't clobbered by the next (identify) run.
LOG="$(new_log cli)"

# USB transfer timeout (ms). The clamp was only needed for the old open-time hang,
# which is fixed now that open() completes. Leaving it ON truncates the match-in-sensor
# verify round-trip at 8s -> WINBIO_E_BAD_CAPTURE. So DEFAULT = no clamp (native/infinite
# waits, correct for capture which legitimately waits for a finger). Pass an arg to
# re-enable a clamp, e.g. `sudo bash scripts/syna-cli.sh 30000`.
if [ -n "${1:-}" ]; then export SYNA_USB_TIMEOUT="$1"; fi

# [U32] Storage backend. DEFAULT (unset/1) = closed adapter's NATIVE WBF storage interface,
# which drives the sensor DB2 child-link write our host stub never issued -> identify MATCHES
# (UPDATE 34). 0=legacy host storage.c (enroll works but identify can't match). 2=native with
# CreateDatabase first, then OpenDatabase.
export SYNA_NATIVE_STORAGE="${SYNA_NATIVE_STORAGE:-}"

wake_sensor
release_from_fprintd

echo "############################################################"
echo "# tudor_cli + HP v11.1 driver, sensor $SENSOR_VID:$SENSOR_PID"
echo "# Store: $STORE"
echo "# Log:   $LOG  (only when SYNA_LOG=1)"
if [ "$SYNA_NATIVE_STORAGE" = "0" ]; then
    echo "# Storage backend: host storage.c (legacy; identify won't match)"
else
    echo "# Storage backend: NATIVE (U32 mode=${SYNA_NATIVE_STORAGE:-1}, default)"
fi
echo "# FIRST type 'y' <Enter> to accept the warning; the menu appears only after open() succeeds."
echo "# Menu (after y): e=enroll  v=verify  i=identify  q=query  w=wipe  s=shutdown"
echo "# Secure sensors may need 2-3 runs to (re-)pair on first ownership change."
echo "############################################################"
echo

# Run DIRECTLY on the terminal (no pipe!). Piping stdout through tee makes glibc
# block-buffer it (4 KB), so the menu/prompts never appear and it looks frozen even
# though input is read fine. A TTY is line-buffered → interactive. For a logged run
# instead, use: SYNA_LOG=1 sudo bash scripts/syna-cli.sh
if [ -n "${SYNA_LOG:-}" ]; then
    stdbuf -oL -eL "$CLI" "$STORE" -vv -t -P"$SENSOR_PID" 2>&1 | tee "$LOG"; ec=${PIPESTATUS[0]}
else
    "$CLI" "$STORE" -vv -t -P"$SENSOR_PID"; ec=$?
fi
echo "### tudor_cli exit code: $ec  (if >128: killed by signal $((ec-128)); 11=SEGV 6=ABRT) ###"
