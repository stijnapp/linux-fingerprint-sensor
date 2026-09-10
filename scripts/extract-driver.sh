#!/bin/bash
# Fetch the closed Synaptics v11.1 driver DLLs from hardware/media you own and
# stage them in hp-driver/. They are NOT shipped with this repo (see hp-driver/README.md).
#
#   ./scripts/extract-driver.sh --from-windows /run/media/$USER/Windows
#   ./scripts/extract-driver.sh --from-softpaq ~/Downloads/sp1xxxxx.exe
#   ./scripts/extract-driver.sh --check                 # just verify what's already there
#
# No root needed if the Windows partition is already mounted (read-only is fine).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HPDRV="$REPO/hp-driver"

BIO_NAME="synaWudfBioUsb111.dll"
ADP_NAME="synaFpAdapter111.dll"
# The exact build this repo was developed against. A mismatch is a warning, not an
# error: other builds of the "111" generation should work (the PE loader binds by
# export name), but the import-coverage table in docs/ was written against these.
BIO_SHA="3974b4ac7fddb0932877a16fe9919bdea5a6dd4ed889e233771f9e33e6357e19"
ADP_SHA="edaf4ebc0b03780de2ac0be9350cb99ace14350da45bcb3dd787d56631b6b25a"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \?//'
    exit "${1:-1}"
}

# Report whether a staged file matches the reference build. Never fatal.
verify_one() {
    local path="$1" want="$2" got
    [ -f "$path" ] || { echo "  MISSING  $(basename "$path")"; return 1; }
    got="$(sha256sum "$path" | cut -d' ' -f1)"
    if [ "$got" = "$want" ]; then
        echo "  ok       $(basename "$path")  (reference build)"
    else
        echo "  differs  $(basename "$path")"
        echo "             got  $got"
        echo "             want $want"
        echo "           Not necessarily a problem — see hp-driver/README.md. Re-run the"
        echo "           -DDBGIMPORT=true loop if the driver aborts on an unresolved import."
    fi
    # A PE check is the real gate: a wrong/truncated file must not reach the build.
    case "$(head -c2 "$path")" in
        MZ) ;;
        *)  die "$(basename "$path") is not a PE binary (no MZ header) — wrong file?" ;;
    esac
    return 0
}

verify_all() {
    echo "Staged in hp-driver/:"
    local rc=0
    verify_one "$HPDRV/$BIO_NAME" "$BIO_SHA" || rc=1
    verify_one "$HPDRV/$ADP_NAME" "$ADP_SHA" || rc=1
    return $rc
}

# Copy the first match for $2 found under $1 into hp-driver/. Prefers the DriverStore
# FileRepository copy (the as-shipped package) over the live System32 one.
harvest() {
    local root="$1" name="$2" found
    found="$(find "$root" -ipath '*DriverStore/FileRepository*' -iname "$name" -type f 2>/dev/null | head -n1)"
    [ -n "$found" ] || found="$(find "$root" -iname "$name" -type f 2>/dev/null | head -n1)"
    [ -n "$found" ] || return 1
    install -Dm0644 "$found" "$HPDRV/$name"
    note "from ${found#"$root"}"
    return 0
}

from_windows() {
    local win="$1"
    [ -d "$win" ] || die "not a directory: $win"
    # Accept either the partition root or the Windows/ dir itself.
    [ -d "$win/Windows" ] && win="$win/Windows"
    [ -d "$win/System32" ] || die "no System32 under $win — is that a Windows partition, and is it mounted?
       Mount it read-only first, e.g.:  sudo mount -o ro /dev/nvme0n1p3 /mnt"
    mkdir -p "$HPDRV"
    echo "Searching $win ..."
    harvest "$win" "$BIO_NAME" || die "$BIO_NAME not found under $win.
       If this machine's driver is a different generation, look for synaWudfBioUsb*.dll
       and see 'Porting to a different sensor' in the README."
    harvest "$win" "$ADP_NAME" || die "$ADP_NAME not found under $win"
}

from_softpaq() {
    local pkg="$1" tmp
    [ -f "$pkg" ] || die "no such file: $pkg"
    local x7z=""
    command -v 7z >/dev/null 2>&1 && x7z=7z
    [ -n "$x7z" ] || { command -v 7zz >/dev/null 2>&1 && x7z=7zz; }
    if [ -z "$x7z" ] && ! command -v cabextract >/dev/null 2>&1; then
        die "need 7z (p7zip) or cabextract to open a SoftPaq without running it"
    fi
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    echo "Unpacking $(basename "$pkg") ..."
    if [ -n "$x7z" ]; then
        "$x7z" x -y -o"$tmp" "$pkg" >/dev/null 2>&1 || true
    else
        cabextract -q -d "$tmp" "$pkg" >/dev/null 2>&1 || true
    fi
    mkdir -p "$HPDRV"
    harvest "$tmp" "$BIO_NAME" || die "$BIO_NAME not found inside $pkg — wrong SoftPaq?"
    harvest "$tmp" "$ADP_NAME" || die "$ADP_NAME not found inside $pkg"
}

[ $# -gt 0 ] || usage
case "$1" in
    --from-windows) [ $# -eq 2 ] || usage; from_windows "$2" ;;
    --from-softpaq) [ $# -eq 2 ] || usage; from_softpaq "$2" ;;
    --check)        verify_all; exit $? ;;
    -h|--help)      usage 0 ;;
    *)              usage ;;
esac

echo
verify_all
echo
echo "Done. Next: ./scripts/setup.sh"
