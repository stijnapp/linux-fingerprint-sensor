# The native driver on Arch / Omarchy

This repo's own driver is the **relink** (see the main README). This page is the other
path: [vojtapl/synaTudorMiS](https://github.com/vojtapl/synaTudorMiS)'s **native**
libfprint driver `synatlsmoc`, which supports `06CB:00FF` directly — no Windows
binaries, no PE loader, no sandbox, no TOD.

On Omarchy it is much the shorter road, because Omarchy already does the whole PAM
half for you. What's missing is only a libfprint that can drive the sensor.

Written and verified on Omarchy (Arch, kernel 7.2), sensor `06cb:00ff`, September 2026.

## Why not the relink here

Arch's `libfprint` has **no TOD support** — the relink's `libtudor_tod.so` needs
`tod_driversdir`, and:

```console
$ pkg-config --variable=tod_driversdir libfprint-2
        # empty; /usr/lib/libfprint-2/ does not exist
```

So the relink path on Arch additionally needs AUR `libfprint-tod`, which conflicts with
both stock `libfprint` and Omarchy's `libfprint-git`. The native driver needs no TOD at
all. (Two things do get easier: Arch has no SELinux, so `scripts/tudor_fdpass.te` is
unnecessary — but Arch also defaults to dbus-broker, so the off-bus fd-passing fix in
`patches/v11.1-00ff.patch` is still required if you do go the relink route.)

## What you build

Two packages, and they must be installed **together in one transaction**:

| Package | What | Why |
| --- | --- | --- |
| `libfprint-vojtapl-synatudormis-git` | AUR; builds vojtapl's libfprint fork | carries the `synatlsmoc` driver |
| `fprintd` 1.94.5 + a patch | Arch's own PKGBUILD + `fprintd-load-store-persistent-data-from-device.patch` | see below — not optional |

### The fprintd patch is mandatory

The driver stores its **sensor pairing data** through a libfprint API the fork adds
(`fp_device_{get,set}_persistent_data`). Stock fprintd never calls it. Then in
`synatlsmoc.c`:

```c
g_object_get (FP_DEVICE (self), "fpi-persistent-data", &pairing_data, NULL);
if ((!synatlsmoc_is_provisioned (self)) || pairing_data == NULL)
  {
    fp_warn ("Need to pair sensor");
    fpi_ssm_next_state (self->task_ssm);   /* OPEN_SEND_PAIR */
```

`NULL` pairing data means **re-pair on every open**. Since each enrollment is tied to a
pairing, every enrolled finger is invalidated each time fprintd restarts. The AUR
package lists fprintd only as an `optdepends` and does not patch it, so this is the
step most likely to be missed.

The patch applies cleanly to fprintd **v1.94.5**, which is what Arch ships.

Usefully, the coupling fails loudly rather than silently: the patched daemon has
`fp_device_get_persistent_data` as an undefined symbol, so if libfprint is ever swapped
back to stock, fprintd refuses to start instead of quietly re-pairing.

## Build

```sh
sudo pacman -S --needed base-devel git meson ninja glib2-devel gtk-doc \
                        pam_wrapper python-dbusmock gobject-introspection

# 1. libfprint fork
git clone https://aur.archlinux.org/libfprint-vojtapl-synatudormis-git.git
cd libfprint-vojtapl-synatudormis-git
#    READ THE PKGBUILD. Then pin it: it ships `#branch=main`, which builds whatever
#    HEAD is at the time. Replace that with the commit you actually reviewed:
#      source=("libfprint::git+https://github.com/vojtapl/libfprint.git#commit=<sha>")
makepkg -s
cd ..

# 2. fprintd + the patch
git clone https://gitlab.archlinux.org/archlinux/packaging/packages/fprintd.git
cd fprintd
curl -O https://raw.githubusercontent.com/vojtapl/synaTudorMiS/master/libfprint/fprintd-load-store-persistent-data-from-device.patch
#    add it to source=(), add 'SKIP' to b2sums, and in prepare() after the cherry-pick:
#      git apply -v ../fprintd-load-store-persistent-data-from-device.patch
#    also set pkgrel=2.1 — see "Keeping it" below
makepkg -s
cd ..

# 3. install BOTH at once (--ask 4 accepts the libfprint conflict-replacement)
sudo pacman -U --ask 4 \
  libfprint-vojtapl-synatudormis-git/*.pkg.tar.zst \
  fprintd/fprintd-*.pkg.tar.zst
```

Two notes on that AUR PKGBUILD: `gobject-introspection` is an **undeclared makedepend**
(the build dies at `g-ir-scanner ... NO` without it), and stock Arch libfprint does ship
`FPrint-2.0.typelib`, so install it rather than building with `-Dintrospection=false`.

## Enroll

```sh
systemctl restart fprintd
fprintd-list "$USER"      # expect "has no fingers enrolled" — NOT "No devices available"
fprintd-enroll "$USER"    # first open pairs the sensor
fprintd-verify
```

## Wire it into Omarchy — but do NOT run the wizard

Omarchy ships `omarchy-setup-security-fingerprint`, which configures `sudo`, `polkit`
and the lock screen, including a nice clamshell gate that falls through to the password
when the lid is shut. **Its PAM half is exactly what you want. Its first step will
destroy your install.**

```sh
if omarchy-pkg-missing libfprint-git fprintd usbutils; then
  sudo pacman -S --needed --noconfirm --ask 4 libfprint-git fprintd usbutils
fi
```

`omarchy-pkg-missing` tests exact package **names** (`pacman -Q libfprint-git`), so it
does not see `libfprint-vojtapl-synatudormis-git` as satisfying `libfprint-git`. It
installs `libfprint-git`, `--ask 4` auto-accepts replacing your driver, enrollment then
fails, and the wizard exits without configuring PAM at all — leaving you with neither.

So apply the same PAM configuration yourself. The lines Omarchy uses:

```sh
GATE='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'

# /etc/pam.d/sudo and /etc/pam.d/polkit-1, each:
#   1. 'auth      sufficient pam_fprintd.so' inserted at line 1
#   2. $GATE inserted immediately before it

# /etc/pam.d/omarchy-lock-fingerprint:
#   auth       required                    pam_fprintd.so
#   account    include                     system-local-login
```

Arm PAM only **after** a successful `fprintd-verify` — that is Omarchy's own reasoning,
and it is right: a reader that is detected but cannot match leaves the login stack
pointing at nothing.

`omarchy-remove-security-fingerprint` undoes the PAM side correctly. Note it ends with
`omarchy-pkg-drop fprintd libfprint libfprint-git`, which will not match the AUR package
name — remove that separately if you want it gone.

## Keeping it

- **`pacman -Syu` will replace your patched fprintd** with the stock one as soon as
  Arch bumps it, and the daemon then fails to start (undefined symbol — see above).
  Setting `pkgrel=2.1` keeps `1.94.5-2.1` ahead of the official `1.94.5-2` so routine
  upgrades leave it alone; a genuine new release still wins, and that's your cue to
  rebuild.
- **Don't run the Omarchy fingerprint wizard afterwards**, for the reason above.
- **Autosuspend.** systemd's `60-autosuspend-fingerprint-reader.hwdb` sets
  `ID_AUTOSUSPEND=1` for `06CB:00FF`, so the sensor sits at `power/control=auto` with a
  2 s delay. The relink work on this same sensor found it corrupts the reply to whatever
  wakes it. If pairing or enrollment misbehaves, that's the first thing to rule out —
  `scripts/99-fingerprint-no-autosuspend.rules` in this repo is driver-independent and
  drops straight into `/etc/udev/rules.d/`.

## Honest status

vojtapl calls the project experimental and has paused development: OpenSSL leaks
memory, there are open FIXMEs, and there are no tests. It is ~4,000 lines of C parsing
sensor input inside a system daemon. Weigh that against the relink, which is a
similar amount of unaudited closed code plus a PE loader — neither is a hardened
product, and the fallback in both cases is your password.
