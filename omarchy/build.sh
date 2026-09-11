#!/bin/bash
# Build both packages into ./packages/. Run as your normal user — NOT root.
#
#   ./build.sh
#
# Produces:
#   packages/libfprint-vojtapl-synatudormis-git-*.pkg.tar.zst
#   packages/fprintd-*.pkg.tar.zst
#
# Then:  sudo ./install.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

[ "$(id -u)" -ne 0 ] || { echo "do NOT run this as root — makepkg refuses. Run ./install.sh with sudo instead." >&2; exit 1; }

command -v makepkg >/dev/null || { echo "needs base-devel: sudo pacman -S --needed base-devel git" >&2; exit 1; }

# fprintd's source tarball is PGP-signed by the fprintd maintainer. makepkg checks that
# against YOUR keyring, so the key has to be imported first or the build dies with
# "unknown public key 9449C2F50996635F". The key is vendored next to the PKGBUILD so you
# can inspect it rather than fetching a fingerprint from a keyserver on faith.
KEY=pkgbuild/fprintd/keys/pgp/D4C501DA48EB797A081750939449C2F50996635F.asc
if ! gpg --list-keys 9449C2F50996635F >/dev/null 2>&1; then
    echo "=== importing the fprintd signing key ==="
    gpg --import "$KEY"
fi

mkdir -p packages

echo
echo "=== 1/2  libfprint fork (the synatlsmoc driver) ==="
( cd pkgbuild/libfprint && makepkg -f --noconfirm )

echo
echo "=== 2/2  fprintd + the persistence patch ==="
# --nocheck: one test (tests/fprintd.py) imports the FPrint GObject namespace, which needs
# FPrint-2.0.typelib. The libfprint fork only builds introspection when g-ir-scanner is
# present, and gobject-introspection is not a declared makedepend of its PKGBUILD, so the
# typelib is usually absent and that one test fails on a perfectly good build. Install
# gobject-introspection and rebuild libfprint if you want the full suite to run.
( cd pkgbuild/fprintd && makepkg -f --noconfirm --nocheck )

# Skip the -debug packages makepkg emits alongside the real ones.
find pkgbuild -maxdepth 2 -name '*.pkg.tar.zst' ! -name '*-debug-*' -exec cp -v {} packages/ \;

echo
echo "=== built ==="
ls -1 packages/*.pkg.tar.zst
sha256sum packages/*.pkg.tar.zst
echo
echo "Next:  sudo ./install.sh"
