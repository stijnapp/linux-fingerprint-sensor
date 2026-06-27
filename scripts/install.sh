#!/bin/bash -e
# Deploy the synaTudor relink driver for the HP Spectre x360 Synaptics "Tudor"
# sensor (06cb:00ff) as a real fprintd backend, on Fedora.
#
# This is the ROOT half of the build/run split:
#   scripts/setup.sh    -> builds work/synaTudor/build (no root, no sensor)
#   scripts/install.sh   -> THIS: deploys that build system-wide (needs root)
#   scripts/syna-cli.sh  -> optional: drive the sensor over the standalone CLI
#
# What gets deployed:
#   - meson install: /sbin/tudor/{libtudor.so,tudor_host,tudor_host_launcher,tudor_cli}
#       (meson stamps install_rpath '$ORIGIN', so tudor_host finds libtudor.so with
#        no patchelf needed), the TOD driver libtudor_tod.so into libfprint's
#        tod_driversdir, the 60-tudor udev rule, the launcher's systemd unit, and
#        both D-Bus files (system-services activation + system.d policy).
#   - our out-of-tree extras meson doesn't know about:
#       * 99-fingerprint-no-autosuspend.rules  (keep the sensor from USB-autosuspending)
#       * tudor_fdpass SELinux module          (lets confined fprintd_t fetch the host
#                                                IPC fd off-bus; see scripts/tudor_fdpass.te)
#   - PAM: authselect 'with-fingerprint' so GDM/login + sudo offer the reader
#       (password always remains a fallback; you can never get locked out).
#
# Re-run safe (idempotent). After an OS reset: setup.sh, then this.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO/work/synaTudor/build"

# --- must be root -----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh needs root; re-running under sudo..."
    exec sudo -E bash "$0" "$@"
fi

# --- the build must exist ---------------------------------------------------
if [ ! -f "$BUILD/libtudor/libtudor.so" ] || [ ! -f "$BUILD/libfprint-tod/libtudor_tod.so" ]; then
    echo "ERROR: build tree not found at $BUILD" >&2
    echo "       Run 'bash $REPO/scripts/setup.sh' first (it builds without root)." >&2
    exit 1
fi

# --- deps for the SELinux module build --------------------------------------
# checkmodule -> checkpolicy ; semodule/semodule_package/restorecon -> policycoreutils
need_pkgs=()
command -v checkmodule       >/dev/null 2>&1 || need_pkgs+=(checkpolicy)
command -v semodule_package  >/dev/null 2>&1 || need_pkgs+=(policycoreutils)
if [ "${#need_pkgs[@]}" -gt 0 ]; then
    echo "Installing SELinux build tools: ${need_pkgs[*]}"
    dnf install -y "${need_pkgs[@]}"
fi

echo "=== 1/6  meson install (binaries, TOD driver, udev rule, unit, D-Bus files) ==="
# Quiesce any running instance first so we don't replace binaries that are in use
# (harmless on a fresh post-reset system where nothing is running yet).
systemctl stop fprintd 2>/dev/null || true
pkill -9 -x tudor_host 2>/dev/null || true
# All install_dirs in the tree are absolute (/sbin/tudor, tod_driversdir, ...), so
# the meson prefix is irrelevant here.
meson install -C "$BUILD"

echo "=== 2/6  no-autosuspend udev rule ==="
install -m 0644 "$REPO/scripts/99-fingerprint-no-autosuspend.rules" \
    /etc/udev/rules.d/99-fingerprint-no-autosuspend.rules

echo "=== 3/6  tudor_fdpass SELinux module ==="
sel_tmp="$(mktemp -d)"
trap 'rm -rf "$sel_tmp"' EXIT
checkmodule -M -m -o "$sel_tmp/tudor_fdpass.mod" "$REPO/scripts/tudor_fdpass.te"
semodule_package -o "$sel_tmp/tudor_fdpass.pp" -m "$sel_tmp/tudor_fdpass.mod"
semodule -i "$sel_tmp/tudor_fdpass.pp"

echo "=== 4/6  restore SELinux labels on the installed binaries ==="
restorecon -RFv /sbin/tudor 2>/dev/null || true
restorecon -Fv /usr/lib64/libfprint-2/tod-1/libtudor_tod.so 2>/dev/null || true

echo "=== 5/6  reload udev / systemd / D-Bus activation ==="
udevadm control --reload-rules && udevadm trigger || true
systemctl daemon-reload || true
# fprintd + the launcher are D-Bus/socket activated; nothing to enable. Drop any
# stale failed state so the next call re-activates cleanly.
systemctl reset-failed fprintd tudor-host-launcher 2>/dev/null || true

echo "=== 6/6  enable fingerprint in PAM (GDM/login + sudo; password stays a fallback) ==="
# Idempotent: only flips the authselect feature if it isn't already on.
if authselect current 2>/dev/null | grep -q 'with-fingerprint'; then
    echo "    with-fingerprint already enabled"
else
    authselect enable-feature with-fingerprint
fi

echo
echo "=================================================================="
echo "Done. Now enroll a finger and test:"
echo "    fprintd-enroll          # swipe through the stages until 'enroll-completed'"
echo "    fprintd-verify          # confirm it matches"
echo "Then: lock the screen (Super+L) and unlock by fingerprint, or run 'sudo -k; sudo true'."
echo
echo "NOTE: the sensor stores templates in its own flash. If verify is flaky after"
echo "      multiple enroll attempts, clear it with a BIOS fingerprint reset and"
echo "      enroll once cleanly (see docs / memory: secure-db2-wall)."
echo "=================================================================="
