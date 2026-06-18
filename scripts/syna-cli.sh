#!/bin/bash
# Run as root:  sudo bash scripts/syna-cli.sh [usb_timeout_ms]
# Launches synaTudor's CLI with our HP v11.1 driver against the 06cb:00ff sensor.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$REPO/work/synaTudor/build/cli/tudor_cli"
STORE="${SUDO_USER:+/home/$SUDO_USER}/.tudor-store"; STORE="${STORE:-$HOME/.tudor-store}"
# Timestamped per-run log so an enroll trace isn't clobbered by the next (identify) run.
# A stable symlink points at the most recent run for convenience.
LOG=/tmp/syna-cli-$(date +%Y%m%d-%H%M%S).log
ln -sf "$LOG" /tmp/syna-cli-latest.log

# USB transfer timeout (ms). The clamp was only needed for the old open-time hang,
# which is fixed now that open() completes. Leaving it ON truncates the match-in-sensor
# verify round-trip at 8s -> WINBIO_E_BAD_CAPTURE. So DEFAULT = no clamp (native/infinite
# waits, correct for capture which legitimately waits for a finger). Pass an arg to
# re-enable a clamp, e.g. `sudo bash scripts/syna-cli.sh 30000`.
if [ -n "$1" ]; then export SYNA_USB_TIMEOUT="$1"; fi

# [EXPERIMENT U32] Storage backend. Unset=host storage.c (default, known-good enroll).
# 1=route enroll/identify through the closed adapter's NATIVE WBF storage interface
#   (drives the sensor DB2 child-link write our host stub never issued) + OpenDatabase.
# 2=same but CreateDatabase first, then OpenDatabase.
# Pass through to the CLI (works whether it was inherited or set inline before sudo).
export SYNA_NATIVE_STORAGE="${SYNA_NATIVE_STORAGE:-}"

# Wake the sensor + free it from fprintd before we grab it.
for d in /sys/bus/usb/devices/*; do
    if [ -f "$d/idVendor" ] && [ "$(cat "$d/idVendor")" = "06cb" ] \
       && [ "$(cat "$d/idProduct" 2>/dev/null)" = "00ff" ]; then
        echo on > "$d/power/control" 2>/dev/null
    fi
done
systemctl stop fprintd 2>/dev/null

echo "############################################################"
echo "# tudor_cli + HP v11.1 driver, sensor 06cb:00ff"
echo "# Store: $STORE   Log: $LOG"
if [ -n "$SYNA_NATIVE_STORAGE" ] && [ "$SYNA_NATIVE_STORAGE" != "0" ]; then
    echo "# Storage backend: NATIVE (U32 mode=$SYNA_NATIVE_STORAGE)"
else
    echo "# Storage backend: host storage.c"
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
if [ -n "$SYNA_LOG" ]; then
    stdbuf -oL -eL "$CLI" "$STORE" -vv -t -P00ff 2>&1 | tee "$LOG"; ec=${PIPESTATUS[0]}
else
    "$CLI" "$STORE" -vv -t -P00ff; ec=$?
fi
echo "### tudor_cli exit code: $ec  (if >128: killed by signal $((ec-128)); 11=SEGV 6=ABRT) ###"
