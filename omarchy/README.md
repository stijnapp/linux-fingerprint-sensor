# The native driver on Arch / Omarchy — build, install, wire up

Everything needed to get `06cb:00ff` working on Arch-family systems using
[vojtapl/synaTudorMiS](https://github.com/vojtapl/synaTudorMiS)'s native libfprint
driver `synatlsmoc`. No Windows binaries, no PE loader, no TOD — none of the relink
machinery in the rest of this repository.

**This is the recommended path on Arch.** See [`../docs/OMARCHY-NATIVE.md`](../docs/OMARCHY-NATIVE.md)
for the reasoning, the failure modes, and an honest assessment of the driver's maturity.
Read that before running anything here.

**Status: working.** Installed on an HP Spectre x360 running Omarchy (Hyprland) on
2026-09-11; `sudo`, polkit and the lock screen all authenticate by fingerprint, with the
password still a fallback everywhere.

## Use

```sh
./build.sh          # as your normal user — makepkg refuses to run as root
sudo ./install.sh   # installs both packages in ONE pacman transaction
fprintd-enroll      # first open pairs the sensor — see the warning below
fprintd-verify
sudo ./setup-pam.sh # sudo + polkit + lock screen
```

Then check that the pairing actually persisted — this is the whole ballgame:

```sh
sudo ls -l /var/lib/fprint/0-persistent/synatlsmoc/   # must exist
systemctl restart fprintd && fprintd-list "$USER"     # finger must SURVIVE the restart
```

⚠️ **Pairing writes to the sensor's flash and invalidates any Windows Hello
enrollments.** If you dual-boot and use Hello, decide before enrolling. Recovery is a
BIOS fingerprint reset, not a brick.

## What's here

| | |
| --- | --- |
| `build.sh` | builds both packages into `packages/` |
| `install.sh` | installs them together, then verifies the driver and symbols |
| `setup-pam.sh` | the PAM wiring Omarchy's wizard would do — `--undo` reverses it |
| `pkgbuild/libfprint/` | the AUR PKGBUILD, pinned to a reviewed commit |
| `pkgbuild/fprintd/` | Arch's PKGBUILD + the persistence patch + the vendored signing key |

Built `.pkg.tar.zst` files are **not** committed — they're machine-built binaries,
fully reproducible from these PKGBUILDs. `build.sh` regenerates them.

## The two things that will bite you

**1. The fprintd patch is mandatory, and upstream's version of it does not work.**

The driver persists its sensor pairing through `fp_device_{get,set}_persistent_data`,
an API only the fork exports. Stock fprintd never calls it, so the sensor re-pairs on
every open and every enrollment — each tied to a pairing — is invalidated.

Upstream's patch adds the calls but saves from `fprint_device_dispose()`, **which never
runs**: fprintd's `main()` ends at `g_main_loop_run` → `store.deinit()` → `return 0`
without ever unreffing the manager, so no device is ever disposed. The pairing lives in
RAM and dies at exit. fprintd idles out ~90 s after use, so the symptom is distinctive:
`fprintd-verify` works right after enrolling, `sudo` fails a few minutes later, then
stops prompting at all, and the journal says

```
Deleted stored finger 7 for user <you> as it is unknown to device.
```

The patch here moves the save into `dev_open_cb()` — right after a successful open, when
the data is known good — and it is a no-op when the stored bytes already match. It also
restores `FILE_STORAGE_PATH` to `/var/lib/fprint` (upstream ships a developer's home
directory) and drops four `g_critical()` debug lines.

The tell that it's working: `Failed to load persistent data` and `Need to pair sensor`
appear once, at the first-ever enroll, and never again.

**2. Never run `omarchy-setup-security-fingerprint` after installing this.** It starts
by installing `libfprint-git`; `omarchy-pkg-missing` matches exact package *names*, so
it won't see the AUR driver as satisfying that, and `--ask 4` auto-accepts replacing
your driver. Enrollment then fails and the wizard exits having configured no PAM at all
— leaving you with neither. `setup-pam.sh` applies the same lines it would have. Its
*removal* script, `omarchy-remove-security-fingerprint`, is safe.

## Keeping it through upgrades

`pacman -Syu` will replace the patched `fprintd` with Arch's as soon as Arch bumps it,
and the daemon then fails to start outright — the patched binary needs
`fp_device_get_persistent_data`, which stock libfprint doesn't export. That loud failure
is deliberate and better than silently re-pairing.

`pkgrel=2.2` keeps `1.94.5-2.2` ahead of the official `1.94.5-2`, so routine upgrades
leave it alone. A genuine new upstream release still wins — and that's your cue to
rebuild, not a bug. Pinning with `IgnorePkg` instead means you stop getting fprintd
security updates silently, which is the worse trade.

## If it misbehaves

systemd's `60-autosuspend-fingerprint-reader.hwdb` sets `ID_AUTOSUSPEND=1` for
`06CB:00FF`, and the relink work on this same sensor found it corrupts the reply to
whatever wakes it. If pairing or enrolling misbehaves:

```sh
sudo install -m0644 ../scripts/99-fingerprint-no-autosuspend.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

It was *not* needed on the tested machine — pairing, enrolling and matching all work
with autosuspend left on. Don't apply it pre-emptively.

Back to stock at any time: `sudo pacman -S libfprint fprintd`, then
`sudo ./setup-pam.sh --undo`.
