#!/bin/bash -e
# Build synaTudor's relink shim (libtudor + tudor_cli) for the HP Spectre x360
# Synaptics "Tudor" sensor 06cb:00ff, using our LOCAL v11.1 driver DLLs in hp-driver/.
#
# Strategy (see captures/FINDINGS.md):
#   synaTudor PE-loads the real Windows driver DLL and shims the Windows/WDF/crypto
#   APIs it calls. The base repo ships a Lenovo "104" driver for 06cb:00be only.
#   MarcelineVPQ/elitebook840 ported it to HP's "110" driver for 06cb:00f0, adding
#   ~10 Win-API shims (firmware.c, user32.c, CAPI-AES) the newer driver needs.
#   Our driver is the HP "111" generation (v11.1) for 06cb:00ff. The 110 port's
#   C/meson/crypt shims are version-agnostic and almost certainly all needed, so we
#   reuse that patch wholesale and only swap in our 111 DLLs at the staging step.
#
# Fedora build deps (run once, see README / step 1):
#   sudo dnf install -y meson ninja-build gcc pkgconf-pkg-config \
#       openssl-devel libusb1-devel
#
# This does NOT need root or the sensor — building is offline. Running does (syna-cli.sh).

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$REPO/work"
SYNA="$WORK/synaTudor"
ELITE="$REPO/references/elitebook840-fingerprint"
HPDRV="$REPO/hp-driver"
SYNA_BASE_COMMIT="31dfdb0"   # pinned base the HP port was built against (== our submodule)

mkdir -p "$WORK"

# 1. Fresh synaTudor tree cloned from our pinned submodule (keeps the submodule clean,
#    gives us a real git repo so `git apply` works predictably).
if [ ! -d "$SYNA/.git" ]; then
    rm -rf "$SYNA"
    git clone "$REPO/references/synaTudor" "$SYNA"
fi
cd "$SYNA"
git checkout -f "$SYNA_BASE_COMMIT"
git clean -fdx >/dev/null 2>&1 || true

# 2. Apply the elitebook HP-port patch: Win-API shims (GetSystemFirmwareTable,
#    USER32/CPowerStateWindow, CAPI AES, LoadLibraryW, GetModuleHandle(NULL) fix),
#    meson wiring, and a libtudor/CLI-only top-level meson. Made against this exact
#    base commit, so it should apply with no rejects.
git apply --reject "$ELITE/patches/synaTudor-hp110.patch"
if find "$SYNA" -name '*.rej' | grep -q .; then
    echo "WARNING: hp110 patch produced .rej files — inspect them:"; find "$SYNA" -name '*.rej'
fi

# 2b. Apply OUR v11.1 / 06cb:00ff deltas on top (WDF stubs etc. the newer driver needs
#     that the v11.0 port didn't). Grows as the DBGWDF/DBGIMPORT loop finds more.
if [ -f "$REPO/patches/v11.1-00ff.patch" ]; then
    git apply --reject "$REPO/patches/v11.1-00ff.patch"
    if find "$SYNA" -name '*.rej' | grep -q .; then
        echo "WARNING: v11.1 patch produced .rej files — inspect them:"; find "$SYNA" -name '*.rej'
    fi
fi

# 3. Stage OUR v11.1 DLLs and override the download script so the build embeds them
#    under the 104 blob names libtudor's meson/loader expect (driver.c references
#    _binary_libtudor_synaWudfBioUsb104_dll_*). Renaming the file is enough — the PE
#    loader resolves the driver's WBF entry points by export name, not file version.
mkdir -p "$SYNA/libtudor/hpdrv"
cp "$HPDRV/synaFpAdapter111.dll"  "$SYNA/libtudor/hpdrv/synaFpAdapter111.dll"
cp "$HPDRV/synaWudfBioUsb111.dll" "$SYNA/libtudor/hpdrv/synaWudfBioUsb111.dll"

cat > "$SYNA/libtudor/download_driver.sh" <<'EOF'
#!/bin/bash -e
# v11.1 override (HP Spectre x360, 06cb:00ff): stage the locally-provided HP "111"
# DLLs into the 104 output names libtudor embeds as binary blobs. No download.
OUT_DIR="$3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HP="$SCRIPT_DIR/hpdrv"
mkdir -p "$OUT_DIR"
cp "$HP/synaFpAdapter111.dll"  "$OUT_DIR/synaFpAdapter104.dll"
cp "$HP/synaWudfBioUsb111.dll" "$OUT_DIR/synaWudfBioUsb104.dll"
EOF
chmod +x "$SYNA/libtudor/download_driver.sh"

# 4. Build CLI + libtudor only, with import debugging ON so any v11.1-only Windows
#    import that isn't shimmed yet logs its name (then add a stub and rebuild).
cd "$SYNA"
rm -rf build
meson setup build -DDBGIMPORT=true -DDBGWDF=true
ninja -C build

echo
echo "=================================================================="
echo "Built: $SYNA/build/  (libtudor.so, tudor_host, tudor_host_launcher,"
echo "       tudor_cli, libfprint-tod/libtudor_tod.so)"
echo
echo "Next, pick a path:"
echo "  fprintd login (real backend):  sudo bash $REPO/scripts/install.sh"
echo "  standalone CLI (poke sensor):  sudo bash $REPO/scripts/syna-cli.sh"
echo "=================================================================="
