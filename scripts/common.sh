# Shared helpers for the sensor-facing scripts. Sourced, not executed.
#
# Porting to another Synaptics Tudor PID: override here (or in the environment) and
# every script, plus the udev rule generated from it, follows.
SENSOR_VID="${SENSOR_VID:-06cb}"
SENSOR_PID="${SENSOR_PID:-00ff}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/work/synaTudor/build"
CLI="$BUILD/cli/tudor_cli"

# Home of the human running this, even under sudo, and even if their home isn't
# /home/<name>. Falls back to root's own home when there is no invoking user.
invoking_home() {
    local user="${SUDO_USER:-${USER:-root}}" home
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    [ -n "$home" ] || home="${HOME:-/root}"
    printf '%s' "$home"
}

STORE="${SYNA_STORE:-$(invoking_home)/.tudor-store}"

# Logs go to a private, root-owned directory. These scripts run as root, so writing
# to a predictable path in world-writable /tmp would let any local user pre-create a
# symlink there and have root follow it.
LOGDIR="${SYNA_LOGDIR:-/var/log/syna-tudor}"
new_log() {
    install -d -m 0750 "$LOGDIR"
    printf '%s/%s-%s.log' "$LOGDIR" "${1:-run}" "$(date +%Y%m%d-%H%M%S)"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This needs root: sudo bash $0 $*" >&2
        exit 1
    fi
}

# Keep the sensor awake: it autosuspends after ~2s and then corrupts the reply to
# whatever wakes it. The installed udev rule does this permanently; this covers
# running from a build tree before install.sh has been run.
wake_sensor() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [ -r "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor")" = "$SENSOR_VID" ] || continue
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$SENSOR_PID" ] || continue
        echo on > "$d/power/control" 2>/dev/null || true
    done
}

# fprintd holds the device open; it is D-Bus activated and comes back by itself on
# the next login or swipe.
release_from_fprintd() {
    systemctl stop fprintd 2>/dev/null || true
}

sensor_present() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [ -r "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor")" = "$SENSOR_VID" ] &&
            [ "$(cat "$d/idProduct" 2>/dev/null)" = "$SENSOR_PID" ] && return 0
    done
    return 1
}

require_cli() {
    [ -x "$CLI" ] || {
        echo "CLI not built: $CLI" >&2
        echo "Run ./scripts/setup.sh first (it builds without root)." >&2
        exit 1
    }
}
