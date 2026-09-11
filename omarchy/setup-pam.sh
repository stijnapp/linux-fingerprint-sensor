#!/bin/bash
# Wire the fingerprint reader into sudo, polkit and the Omarchy lock screen.
#
#   sudo ./setup-pam.sh          # configure
#   sudo ./setup-pam.sh --undo   # remove again
#
# WHY NOT JUST RUN `omarchy-setup-security-fingerprint`?
# Because it starts with:
#     omarchy-pkg-missing libfprint-git fprintd usbutils
#     && sudo pacman -S --needed --noconfirm --ask 4 libfprint-git fprintd usbutils
# `omarchy-pkg-missing` tests exact package NAMES, so it does not see
# libfprint-vojtapl-synatudormis-git as satisfying `libfprint-git`. It would install
# libfprint-git, and `--ask 4` would auto-accept replacing the driver we just built —
# after which enrollment fails and the wizard bails without configuring PAM at all.
#
# So this applies the same PAM configuration the wizard would, and nothing else.
# The lines below are copied from /usr/bin/omarchy-setup-security-fingerprint; if
# Omarchy changes them, diff that file against this one.
#
# Undoing is Omarchy's own job and its script is safe to use:
#   omarchy-remove-security-fingerprint   (also drops the packages — see --undo below)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "needs root: sudo $0 $*" >&2; exit 1; }

# Clamshell gate: with the lid shut the reader is unreachable, so skip fingerprint
# (success=1) and drop straight to the password prompt instead of blocking on the
# reader until it times out.
GATE='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'

undo() {
    echo "Removing fingerprint auth from PAM..."
    for f in /etc/pam.d/sudo /etc/pam.d/polkit-1; do
        [ -f "$f" ] || continue
        if grep -Eq 'pam_fprintd\.so|omarchy-hw-laptop-closed' "$f"; then
            sed -i -e '/pam_fprintd\.so/d' -e '/omarchy-hw-laptop-closed/d' "$f"
            echo "  cleaned $f"
        fi
    done
    rm -f /etc/pam.d/omarchy-lock-fingerprint && echo "  removed /etc/pam.d/omarchy-lock-fingerprint"
    echo "Done. Packages left in place — remove them with:  pacman -R fprintd libfprint-vojtapl-synatudormis-git"
    exit 0
}
[ "${1:-}" = "--undo" ] && undo

# Refuse to arm PAM against a reader that cannot actually match — the same reasoning
# Omarchy's wizard uses when it configures PAM only after a successful verify.
user="${SUDO_USER:-$USER}"
# fprintd-list prints "Fingerprints for user X on <dev>:" when prints exist, and
# "User X has no fingers enrolled for <dev>." when they don't (utils/list.c).
if ! fprintd-list "$user" 2>/dev/null | grep -q "^Fingerprints for user"; then
    echo "ERROR: no enrolled fingerprints for '$user'." >&2
    echo "       Run 'fprintd-enroll $user' and 'fprintd-verify' first — arming PAM" >&2
    echo "       before a print exists points the login stack at nothing." >&2
    exit 1
fi

echo "Configuring sudo..."
if ! grep -q pam_fprintd.so /etc/pam.d/sudo; then
    sed -i '1i auth      sufficient pam_fprintd.so' /etc/pam.d/sudo
    echo "  added pam_fprintd"
fi
if ! grep -q 'omarchy-hw-laptop-closed' /etc/pam.d/sudo; then
    sed -i "/pam_fprintd\.so/i $GATE" /etc/pam.d/sudo
    echo "  added clamshell gate"
fi

echo "Configuring polkit..."
if [ -f /etc/pam.d/polkit-1 ]; then
    grep -q 'pam_fprintd.so' /etc/pam.d/polkit-1 || \
        sed -i '1i auth      sufficient pam_fprintd.so' /etc/pam.d/polkit-1
    grep -q 'omarchy-hw-laptop-closed' /etc/pam.d/polkit-1 || \
        sed -i "/pam_fprintd\.so/i $GATE" /etc/pam.d/polkit-1
else
    tee /etc/pam.d/polkit-1 >/dev/null <<EOF
$GATE
auth      sufficient pam_fprintd.so
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
EOF
fi

echo "Configuring lock screen..."
tee /etc/pam.d/omarchy-lock-fingerprint >/dev/null <<'EOF'
#%PAM-1.0
auth       required                    pam_fprintd.so
account    include                     system-local-login
EOF

echo
echo "Done — fingerprint now works for sudo, polkit, and the lock screen (Super+Ctrl+L)."
echo "Your password remains a fallback everywhere; test with:  sudo -k; sudo true"
