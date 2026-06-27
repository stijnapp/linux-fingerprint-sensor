#!/bin/bash
# Read-only dump of the sensor's on-flash DB2 store (06cb:00ff). Diagnostic only:
# it opens the device, lets the closed driver enumerate DB2 at open (which at
# LOG_VERBOSE dumps the cleartext command frames via the bcrypt peek), then 's' =
# clean shutdown. It does NOT enroll, delete, wipe, or format anything.
#
# Use it to see what's ACTUALLY on the sensor vs. what fprintd thinks (fprintd-list
# only reflects /var/lib/fprint, not the sensor flash — the two can desync; see
# README "resetting templates does not reach the sensor").
#
#   sudo bash scripts/syna-db2-dump.sh
#
# Decode (per work/re-notes/template-load-chain.md): opcodes 9e=GET_DB_INFO
# 9f=GET_OBJECT_LIST a0=GET_OBJECT_INFO a1=GET_OBJECT_DATA; the byte after 9f is the
# list type 01=users 02=top-level templates 03=children-of-<guid>. The matcher loads
# ONLY the children of the common-property user (the one whose a0 info returns ..0100..).
# Top-level templates (9f02) that aren't under that user are orphans.
#
# Known wart: the CLI SEGFAULTs on the final teardown command (after the dump). The
# enumeration above it is complete and valid; ignore the trailing "dumped core".
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$REPO/work/synaTudor/build/cli/tudor_cli"
STORE="/home/${SUDO_USER:-$USER}/.tudor-store"
LOG="${1:-/tmp/syna-db2-dump.log}"

if [ "$(id -u)" -ne 0 ]; then echo "needs root: sudo bash $0" >&2; exit 1; fi
[ -x "$CLI" ] || { echo "CLI not built: $CLI (run scripts/setup.sh first)" >&2; exit 1; }

# Free the sensor from fprintd and keep it awake, then open(=enumerate)+shutdown.
systemctl stop fprintd 2>/dev/null
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] && [ "$(cat "$d/idVendor")" = "06cb" ] \
      && [ "$(cat "$d/idProduct" 2>/dev/null)" = "00ff" ] && echo on > "$d/power/control" 2>/dev/null
done

printf 'y\ns\n' | timeout 70 "$CLI" "$STORE" -vv -t -P00ff > "$LOG" 2>&1
ec=$?
chmod 0644 "$LOG" 2>/dev/null
echo "cli exit $ec   full log: $LOG"
echo "----- DB2 object enumeration (open-time) -----"
grep -iE 'CRYPTO (TX|RX)|OpenDatabase|NumCurrentUsers|Error opening|tudor device opened' "$LOG" \
  | grep -iE 'DB2_|OpenDatabase|NumCurrentUsers|Error|opened|RX' | head -80
echo "----------------------------------------------"
echo "fprintd is socket/D-Bus activated; it auto-reactivates on the next login or swipe."
