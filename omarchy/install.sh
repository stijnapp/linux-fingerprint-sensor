#!/bin/bash
# Install the native Synaptics Tudor driver (vojtapl/synatlsmoc) on Omarchy.
#
#   sudo ./install.sh
#
# Installs BOTH packages in ONE pacman transaction. That is not a style choice:
# the patched fprintd links fp_device_{get,set}_persistent_data, which only the
# forked libfprint exports, so a half-install leaves fprintd unable to start.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "needs root: sudo $0" >&2; exit 1; }

# Globs, not pinned filenames: the versions move when you rebuild.
shopt -s nullglob
LIBFPRINT=("$DIR"/packages/libfprint-vojtapl-synatudormis-git-*.pkg.tar.zst)
FPRINTD=("$DIR"/packages/fprintd-*.pkg.tar.zst)
shopt -u nullglob

if [ ${#LIBFPRINT[@]} -eq 0 ] || [ ${#FPRINTD[@]} -eq 0 ]; then
    echo "No built packages in $DIR/packages/." >&2
    echo "Build them first (as your normal user, not root):" >&2
    echo "    ./build.sh" >&2
    exit 1
fi
[ ${#LIBFPRINT[@]} -eq 1 ] && [ ${#FPRINTD[@]} -eq 1 ] || {
    echo "More than one build in $DIR/packages/ — delete the stale ones:" >&2
    printf '    %s\n' "${LIBFPRINT[@]}" "${FPRINTD[@]}" >&2
    exit 1
}
LIBFPRINT="${LIBFPRINT[0]}"
FPRINTD="${FPRINTD[0]}"

echo "=== what this replaces ==="
pacman -Q libfprint fprintd 2>&1 | sed 's/^/  /' || true
echo
echo "  libfprint  -> libfprint-vojtapl-synatudormis-git (conflicts with stock libfprint)"
echo "  fprintd    -> Arch's own source + the persistent-data patch (with the fixed save hook)"
echo
read -rp "Proceed? [y/N] " ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit 1; }

# --ask 4 accepts the libfprint conflict-replacement in the same transaction.
pacman -U --needed --ask 4 "$LIBFPRINT" "$FPRINTD"

echo
echo "=== verify ==="
pacman -Q libfprint-vojtapl-synatudormis-git fprintd
echo
echo -n "  driver present in libfprint: "
# grep reads the .so directly (-a). Do NOT pipe `strings` into `grep -q`: grep exits
# at the first match, strings dies on SIGPIPE (141), and `set -o pipefail` above turns
# that into a failed pipeline -- printing "NO" even when the driver is present.
grep -qa "FpiDeviceSynaTlsMoc" /usr/lib/libfprint-2.so.2 2>/dev/null \
    && echo "yes" || echo "NO — something is wrong, stop here"
echo -n "  fprintd can resolve its symbols: "
if ldd /usr/lib/fprintd 2>/dev/null | grep -q "not found"; then
    echo "NO"; ldd /usr/lib/fprintd | grep "not found"
else
    echo "yes"
fi

systemctl daemon-reload || true
systemctl reset-failed fprintd 2>/dev/null || true

cat <<'NEXT'

=================================================================
Installed. NOT yet paired or enrolled — that is the next step and
it is the one that touches the sensor's flash.

  1. Check the daemon can see the reader:
         systemctl restart fprintd
         fprintd-list "$SUDO_USER"        # expect "no fingers enrolled", NOT "no devices"

  2. Enroll (this pairs the sensor on first open):
         fprintd-enroll "$SUDO_USER"
         fprintd-verify

  3. Wire it into sudo / polkit / lock screen:
         sudo ./setup-pam.sh

If step 1 says "no devices available", or step 2 fails with corrupted
replies, try disabling USB autosuspend first — this sensor is known to
corrupt the reply to whatever wakes it:

     sudo install -m0644 ../scripts/99-fingerprint-no-autosuspend.rules /etc/udev/rules.d/
     sudo udevadm control --reload-rules && sudo udevadm trigger

To go back to stock at any time:
     sudo pacman -S libfprint fprintd
=================================================================
NEXT
