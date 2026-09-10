#!/bin/bash
# Run as root:  sudo bash scripts/syna-debug.sh [wait_secs]
# Launches tudor_cli non-interactively (auto-answers 'y'), and if it's still alive
# after WAIT secs (i.e. hung, not aborted), captures all-thread backtraces so we can
# see exactly what it's blocked on, then kills it. For diagnosing HANGS (vs the
# abort-on-missing-stub loop, which syna-cli.sh handles fine).
set -u
source "$(dirname "$0")/common.sh"
require_root "$@"
require_cli

LOG="$(new_log debug)"
BT="${LOG%.log}.bt.txt"
WAIT="${1:-12}"

# Past the 8s bulk-timeout clamp by default, so a clamped bulk read would already have
# failed; anything still hung at WAIT secs is a non-clamped wait (control xfer, event, lock).
export SYNA_USB_TIMEOUT=8000

wake_sensor
release_from_fprintd

echo "### launching tudor_cli (auto 'y'), will snapshot stacks after ${WAIT}s if still running" | tee "$LOG"
printf 'y\n' | "$CLI" "$STORE" -v -t -P"$SENSOR_PID" >>"$LOG" 2>&1 &
PID=$!

sleep "$WAIT"

if kill -0 "$PID" 2>/dev/null; then
    echo "### PID $PID still alive after ${WAIT}s -> HUNG. Capturing backtraces to $BT ###" | tee -a "$LOG"
    {
        echo "===== eu-stack (all threads) ====="
        eu-stack -p "$PID" 2>&1
        echo; echo "===== gdb thread apply all bt ====="
        gdb -p "$PID" -batch -nx \
            -ex "set pagination off" \
            -ex "info threads" \
            -ex "thread apply all bt" 2>&1
    } | tee "$BT"
    echo "### killing $PID ###" | tee -a "$LOG"
    kill -9 "$PID" 2>/dev/null
else
    echo "### PID $PID already exited before ${WAIT}s (not a hang) — see $LOG ###" | tee -a "$LOG"
fi

echo
echo "Tail of run log ($LOG):"
tail -n 25 "$LOG"
echo
echo "Backtrace saved to $BT"
