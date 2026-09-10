#!/bin/bash
# Reverse scripts/install.sh: take the fingerprint reader back out of the login path
# and remove everything it deployed.
#
#   sudo ./scripts/uninstall.sh            # remove the driver, keep enrolled prints
#   sudo ./scripts/uninstall.sh --purge    # ...and delete fprintd's enrolled templates
#   sudo ./scripts/uninstall.sh --dry-run  # print what would happen, change nothing
#
# PAM is disarmed FIRST and everything else is best-effort, so a partial run can never
# leave a login stack pointing at a driver that is no longer there. Your password
# remains a valid login the entire time.
#
# What this canNOT undo: templates already written to the sensor's own flash (DB2).
# That store is separate from /var/lib/fprint and survives everything here — see
# docs/RESET.md. Only a BIOS fingerprint reset clears it.
set -u
source "$(dirname "$0")/common.sh"

DRY=0; PURGE=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --purge)   PURGE=1 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 1 ;;
    esac
done

[ "$DRY" -eq 1 ] || require_root "$@"

run() {
    if [ "$DRY" -eq 1 ]; then
        echo "    would: $*"
    else
        "$@" 2>/dev/null || true
    fi
}
rm_file() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    if [ "$DRY" -eq 1 ]; then echo "    would remove: $1"; else rm -f "$1"; fi
}

echo "=== 1/6  take fingerprint OUT of PAM (first, so nothing can wedge a login) ==="
if command -v authselect >/dev/null 2>&1; then
    # Fedora / RHEL
    if authselect current 2>/dev/null | grep -q 'with-fingerprint'; then
        run authselect disable-feature with-fingerprint
    else
        echo "    with-fingerprint not enabled"
    fi
elif [ -x /usr/bin/omarchy-remove-security-fingerprint ]; then
    # Omarchy owns its own PAM edits (sudo, polkit, lock screen) — let it undo them.
    echo "    delegating to omarchy-remove-security-fingerprint"
    echo "    NOTE: that also drops the fprintd/libfprint packages. Run it yourself if"
    echo "          you want that; this script leaves your PAM stacks alone."
else
    # Anything else: report rather than edit stacks we did not write.
    if grep -rl 'pam_fprintd' /etc/pam.d/ 2>/dev/null | grep -q .; then
        echo "    pam_fprintd still referenced in:"
        grep -rl 'pam_fprintd' /etc/pam.d/ 2>/dev/null | sed 's/^/      /'
        echo "    Remove those lines by hand — this script will not edit PAM stacks it"
        echo "    did not write. Do it BEFORE rebooting."
    else
        echo "    pam_fprintd not referenced anywhere in /etc/pam.d"
    fi
fi

echo "=== 2/6  stop anything holding the device ==="
run systemctl stop fprintd
run systemctl stop tudor-host-launcher
run pkill -9 -x tudor_host

echo "=== 3/6  remove installed files ==="
# meson records exactly what it installed; use that when it's there so we remove what
# this build actually deployed rather than a guessed list.
inst_log="$BUILD/meson-logs/install-log.txt"
if [ -f "$inst_log" ]; then
    echo "    using $inst_log"
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        rm_file "$line"
    done < "$inst_log"
else
    echo "    no meson install log (build tree gone?) — removing the known paths"
    rm_file /sbin/tudor/libtudor.so
    rm_file /sbin/tudor/tudor_host
    rm_file /sbin/tudor/tudor_host_launcher
    rm_file /sbin/tudor/tudor_cli
    for d in /usr/lib64/libfprint-2/tod-1 /usr/lib/libfprint-2/tod-1 \
             /usr/lib/x86_64-linux-gnu/libfprint-2/tod-1; do
        rm_file "$d/libtudor_tod.so"
    done
    rm_file /usr/lib/systemd/system/tudor-host-launcher.service
    rm_file /usr/share/dbus-1/system-services/io.github.popax21.tudor.service
    rm_file /usr/share/dbus-1/system.d/io.github.popax21.tudor.conf
    for d in /usr/lib/udev/rules.d /etc/udev/rules.d /lib/udev/rules.d; do
        rm_file "$d/60-tudor-libfprint-tod.rules"
    done
fi
[ "$DRY" -eq 1 ] || rmdir /sbin/tudor 2>/dev/null || true

echo "=== 4/6  remove the no-autosuspend udev rule ==="
rm_file /etc/udev/rules.d/99-fingerprint-no-autosuspend.rules

echo "=== 5/6  remove the SELinux module (if this system has one) ==="
if command -v semodule >/dev/null 2>&1 && semodule -l 2>/dev/null | grep -q '^tudor_fdpass'; then
    run semodule -r tudor_fdpass
else
    echo "    tudor_fdpass not loaded (or no SELinux here)"
fi

echo "=== 6/6  reload udev / systemd / D-Bus ==="
run udevadm control --reload-rules
run udevadm trigger
run systemctl daemon-reload
run systemctl reset-failed fprintd tudor-host-launcher

if [ "$PURGE" -eq 1 ]; then
    echo
    echo "=== --purge: deleting fprintd's enrolled templates ==="
    echo "    (host side only — the sensor's own flash is NOT touched, see docs/RESET.md)"
    rm_file "$STORE"
    if [ "$DRY" -eq 1 ]; then
        echo "    would remove: /var/lib/fprint/*"
    else
        rm -rf /var/lib/fprint/* 2>/dev/null || true
    fi
fi

echo
echo "=================================================================="
if [ "$DRY" -eq 1 ]; then
    echo "Dry run — nothing was changed."
else
    echo "Removed. Log in with your password as usual."
    echo
    echo "Still on the sensor: any templates in its own flash. Nothing on Linux"
    echo "clears those — a BIOS fingerprint reset does. See docs/RESET.md."
fi
echo "=================================================================="
