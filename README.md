# Linux fingerprint login for the Synaptics "Tudor" sensor `06cb:00ff`

A working **fprintd** backend for the Synaptics fingerprint reader **USB ID `06cb:00ff`**
(Synaptics UWP WBDI / "Tudor" family, HP driver **v11.1**), as found in the HP Spectre
x360. Tested on **Fedora Workstation 44**.

**Status: working.** Enroll, verify, **GDM graphical login**, lock screen, and **`sudo`**
all authenticate by fingerprint, with the password always available as a fallback (you
cannot get locked out).

This is **not** a from-scratch libfprint driver. Instead we **relink Synaptics' own
closed Windows driver DLLs** to run on Linux, using
[Popax21/synaTudor](https://github.com/Popax21/synaTudor), adapted for our specific sensor
and driver version.

> ### ⚠️ Read this before building: there is now a native driver for this exact sensor
>
> When this repo was written it assumed a clean-room driver was impossible for this
> sensor family. **That was wrong for `06cb:00ff`.**
> [vojtapl/synaTudorMiS](https://github.com/vojtapl/synaTudorMiS) is a native libfprint
> driver (`synatlsmoc`) that lists `06CB:00FF` as **tested** — it is the author's own
> sensor — and it needs no Windows binaries, no PE loader, no sandbox and no TOD.
> Work on it predates this repository; we simply did not find it.
>
> **If you just want your reader to work, try that first.** See
> [Which path should you take](#which-path-should-you-take).
>
> This repo remains useful as: a working fallback, a map of the relink approach, and a
> written-up account of the blockers (DB2 child-linking, dbus-broker fd-drop, sandbox
> limits) that anyone touching this hardware will hit either way.

> If you have a **different Synaptics Tudor sensor** (e.g. `06cb:00be`, `06cb:00f0`, or
> another HP/Lenovo PID), this repo is meant to be a usable map of the whole adaptation —
> see [Porting to a different sensor](#porting-to-a-different-sensor).

---

## Which path should you take

| | [vojtapl/synaTudorMiS](https://github.com/vojtapl/synaTudorMiS) (native) | this repo (relink) |
| --- | --- | --- |
| Windows driver binaries | none | you must supply them |
| libfprint | a patched fork, drop-in | needs a **TOD**-enabled build |
| fprintd | needs a small patch (persistent pairing data) | stock |
| Moving parts | one libfprint driver | PE loader + sandboxed host + D-Bus launcher + TOD shim |
| Upstream future | aiming at libfprint proper | permanently out-of-tree |
| Status | "just works", author paused development | working, documented here |

**Try the native driver first.** Come back here if it doesn't work on your machine, or
if you want the relink for its own sake. The rest of this README is the relink.

## Quick start (this exact sensor, Fedora)

```sh
# 0. build deps (once)
sudo dnf install -y meson ninja-build gcc pkgconf-pkg-config openssl-devel libusb1-devel

# 1. supply the closed driver DLLs — they are NOT in this repo (hp-driver/README.md).
#    From your own Windows partition, or from an HP SoftPaq:
./scripts/extract-driver.sh --from-windows /run/media/$USER/Windows

# 2. build the relinked driver (no root, no sensor needed — it's offline;
#    fetches the reference submodules on first run)
./scripts/setup.sh

# 3. deploy it system-wide as an fprintd backend (needs root)
sudo ./scripts/install.sh

# 4. enroll — the normal Fedora way is the GUI:
#      Settings ▸ Users ▸ Fingerprint Login   (you choose which finger; the same
#      panel also removes enrolled fingers). Or on the command line:
#      fprintd-enroll        # swipe through the stages until "enroll-completed"
#      fprintd-verify        # confirm it matches

# 5. test: lock the screen (Super+L) and unlock by fingerprint, or:  sudo -k; sudo true
```

Reinstalling from scratch (e.g. on a fresh OS install) is **`extract-driver.sh`,
`setup.sh`, `install.sh`**, then enroll.

To take it all back out again — PAM is disarmed first, so this cannot lock you out:

```sh
sudo ./scripts/uninstall.sh --dry-run   # see what it would do
sudo ./scripts/uninstall.sh             # remove it
```

> **Caveat — resetting templates does not reach the sensor.** Removing fingerprints (in the
> GUI or with `fprintd-delete`) clears *fprintd's* records, but the sensor keeps its
> templates in its own flash (DB2) and there is **no verified path that erases that flash
> from Linux**, so the two **desync**: the GUI shows "no fingerprints" while stale templates
> stay on the sensor. (Confirmed by reading the sensor's DB2 — a one-finger install was
> found still holding four orphan template trees from past enroll/delete cycles. They don't
> cause false matches, since only the live finger is loaded into the matcher, but they never
> go away.) The only **proven** clean wipe is a **BIOS fingerprint reset**; do that and
> enroll once if matching gets flaky. **The recipes for resetting, re-enrolling and
> removing are in [`docs/RESET.md`](docs/RESET.md)**; the background is
> [The blockers we hit](#the-blockers-we-hit-and-how-they-were-solved), point 8.

There is also a standalone CLI path for poking the sensor directly without fprintd:
`sudo ./scripts/syna-cli.sh` (menu: `e`nroll / `v`erify / `i`dentify / `q`uery / `w`ipe).

---

## How it works (the relink, in one picture)

```
  fprintd  ──D-Bus──►  libfprint  ──loads──►  libtudor_tod.so   (TOD driver)
                                                   │
                                          spawns + talks over a
                                          socketpair(AF_UNIX, SOCK_DGRAM)
                                                   ▼
                                          tudor_host   (sandboxed, /sbin/tudor/)
                                                   │  PE-loads + shims:
                                                   ▼
                            ┌─────────────────────────────────────────────┐
                            │  libtudor.so  =  a userspace PE loader +     │
                            │  Linux implementations of every Windows /    │
                            │  WDF / CAPI / BCrypt API the driver imports   │
                            └─────────────────────────────────────────────┘
                                                   │
                              synaWudfBioUsb111.dll + synaFpAdapter111.dll
                              (the REAL closed Synaptics driver, unmodified)
                                                   │
                          USB calls → libusb        crypto → OpenSSL
                                                   ▼
                                        sensor 06cb:00ff (TLS 1.2, match-in-sensor)
```

`libtudor` never reimplements the Synaptics protocol. It loads the genuine Windows driver
binary into memory and answers every Windows API the binary calls, routing USB to
**libusb** and crypto to **OpenSSL**. The closed driver does its own TLS/AES handshake and
talks to the sensor exactly as it would on Windows. fprintd sees a normal libfprint device.

A root, D-Bus-activated **launcher** (`tudor_host_launcher`) starts the sandboxed
`tudor_host` and hands its IPC socket to fprintd. The whole thing is described in
`docs/V11.1-ADAPTATION.md`.

---

## Repository layout — what every file is

What each directory and file in the repository is for.

### Top level

| Path          | What it is                                                                                         |
| ------------- | -------------------------------------------------------------------------------------------------- |
| `README.md`   | this file                                                                                          |
| `LICENSE`, `COPYING.md` | LGPL-2.1-or-later, and what this repo does and does not ship (read `COPYING.md`)          |
| `scripts/`    | everything you run — build, deploy, debug, and the support files they install                      |
| `patches/`    | **our** changes to synaTudor, as a single git patch (the real source of our work)                  |
| `hp-driver/`  | where the closed HP **v11.1** driver DLLs go — **not shipped**; you supply them, see its README    |
| `references/` | upstream projects as git submodules (synaTudor + the elitebook840 port)                            |
| `work/`       | build tree + reverse-engineering notes (generated/scratch; not the source of truth)                |
| `docs/`       | the adaptation write-up (`V11.1-ADAPTATION.md`) and the reset/removal runbook (`RESET.md`)         |
| `captures/`   | Windows USB captures + `FINDINGS.md` — the dead-end investigation that made us pivot to the relink |
| `.gitmodules` | declares the two submodules under `references/`                                                    |

### `scripts/` — the things you run, and the support files they install

| File                                  | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `setup.sh`                            | **build** (no root). Clones the pinned synaTudor base, applies the elitebook hp110 patch then **our** `v11.1-00ff.patch`, stages the HP v11.1 DLLs, runs `meson`/`ninja`. Output: `work/synaTudor/build/`.                                                                                                                                                                                                                                                                                                                |
| `install.sh`                          | **deploy** (root). `meson install` (binaries → `/sbin/tudor`, the TOD driver, udev rule, systemd unit, D-Bus files) + installs the autosuspend rule + the SELinux module + enables fingerprint in PAM. Idempotent.                                                                                                                                                                                                                                                                                                        |
| `uninstall.sh`                        | **remove** (root). Reverses `install.sh` in the safe order — PAM first, so a partial run can never point a login stack at a driver that is gone. `--dry-run` to preview, `--purge` to also drop host-side templates.                                                                                                                                                                                                                              |
| `extract-driver.sh`                   | stage the closed DLLs into `hp-driver/` from your own Windows partition or an HP SoftPaq, and verify them against the reference hashes. Required before `setup.sh` — the binaries are not in this repo.                                                                                                                                                                                                                                              |
| `syna-status.sh`                      | show fprintd's records next to what's actually in the sensor's flash — the desync in one view. `--deep` (root) enumerates DB2.                                                                                                                                                                                                                                                                                                                       |
| `common.sh`                           | sourced by the sensor-facing scripts: the VID/PID (**change it here to port**), store/log paths, sensor-wake and fprintd-release helpers.                                                                                                                                                                                                                                                                                                           |
| `syna-cli.sh`                         | run the standalone `tudor_cli` against the sensor (no fprintd) — for poking enroll/verify/identify directly.                                                                                                                                                                                                                                                                                                                                                                                                              |
| `syna-debug.sh`                       | launch the CLI non-interactively and, if it **hangs**, snapshot all-thread backtraces (`eu-stack` + `gdb`). A diagnostic from the debugging phase; not needed for normal use.                                                                                                                                                                                                                                                                                                                                             |
| `99-fingerprint-no-autosuspend.rules` | **udev rule.** Keeps the sensor from USB-autosuspending. These match-in-sensor readers sleep after ~2 s; the next command wakes them mid-transfer and the reply comes back corrupted. `install.sh` copies this to `/etc/udev/rules.d/`.                                                                                                                                                                                                                                                                                   |
| `tudor_fdpass.te`                     | **SELinux policy source** (`.te` = _type enforcement_). Three `allow` rules letting the confined `fprintd_t` domain receive the host IPC file descriptor over the launcher's private socket. `install.sh` compiles it (`checkmodule` → `semodule_package` → `semodule -i`) and loads it. SELinux stays **enforcing**; this grants exactly that one path and nothing else. The header comment explains why it's needed (dbus-broker drops the launcher when it returns a unix fd over D-Bus, so the fd is passed off-bus). |

> **File-type glossary:**
>
> - `.patch` / `.diff` — unified-diff text produced by `git diff`. Apply with `git apply`.
>   `patches/v11.1-00ff.patch` is **our entire contribution** as a diff against upstream
>   synaTudor. (`.patch` and `.diff` are the same format; we just use `.patch` for the kept one.)
> - `.rules` — a **udev** rule file; tells the kernel's device manager to do something when
>   a matching device appears (here: don't autosuspend the sensor).
> - `.te` — **SELinux** Type Enforcement source; compiled into a loadable policy module.
> - `.pcap` / `.pcapng` — captured network/USB packets (Wireshark format). See `captures/`.
> - `.dll` / `.cat` / `.inf` — the Windows driver: the code, its catalog signature, and its
>   install manifest. We only use the two `.dll`s.

### `patches/v11.1-00ff.patch` — the actual work

A single git patch (17 files) applied on top of upstream synaTudor + the elitebook hp110
patch. This is where all of our adaptation lives: the off-bus fd-passing, the sandbox
resource-limit fix, the native-storage enroll routing, the verify-as-identify logic, the
USB-serial device probe, extra Windows API stubs, and so on. It is validated to apply
cleanly (0 rejects) on a fresh base. **If you change driver source, regenerate this patch**
— it, not the `work/` tree, is what `setup.sh` re-applies on a clean build.

### `hp-driver/` — the closed binaries (load-bearing, **not shipped**)

The genuine Synaptics v11.1 ("111") Windows driver. **This repository does not contain
it** — it is Synaptics' copyrighted binary and not ours to redistribute. You supply your
own copy from hardware you own, and `setup.sh` embeds it into the build (renamed to the
`104` names libtudor expects).

```sh
./scripts/extract-driver.sh --from-windows /run/media/$USER/Windows
./scripts/extract-driver.sh --from-softpaq ~/Downloads/spXXXXXX.exe
./scripts/extract-driver.sh --check          # verify what's staged
```

| File                    | What                                                                      |
| ----------------------- | ------------------------------------------------------------------------- |
| `synaWudfBioUsb111.dll` | the UMDF USB driver — **contains the matcher and the DB2 template logic** |
| `synaFpAdapter111.dll`  | thin WBF adapter shim (the `Wbio*Interface` surface libtudor drives)      |

[`hp-driver/README.md`](hp-driver/README.md) has the exact paths, the reference SHA-256s,
and the driver version this was developed against.

### `references/` — upstream, as submodules (don't edit)

| Submodule                  | Why it's here                                                                                                                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `synaTudor`                | the relink engine itself; pinned at commit `31dfdb0` (the base our patches target).                                                                                                                  |
| `elitebook840-fingerprint` | a port of synaTudor to the neighbouring `06cb:00f0` sensor. We reuse its `synaTudor-hp110.patch` wholesale (the Windows-API shims the newer HP driver generation needs) and its no-autosuspend rule. |

### `work/` — generated, not source

| Path              | What                                                                                                                                                                                                                                                                                                                                                        |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `work/synaTudor/` | a throwaway clone that `setup.sh` builds in (base + patches applied). The live build is `work/synaTudor/build/`. Reproducible from scratch — safe to delete and rebuild.                                                                                                                                                                                    |
| `work/re-notes/`  | static reverse-engineering notes that cracked the storage bug: `template-load-chain.md` (how the closed driver loads templates into the matcher, with the decoded DB2 opcode stream) and the DLL `*.exports.txt` / `*.strings.txt` interface dumps. The 12 MB `bio.disasm.txt` an earlier revision committed is gone — regenerate it when you need it with `objdump -d hp-driver/synaWudfBioUsb111.dll > work/re-notes/bio.disasm.txt` (see `COPYING.md`). |

### `captures/` — the Windows-capture dead end (kept as evidence)

These `.pcap`/`.pcapng` files are **not** used by the driver. They document _why_ a
clean from-scratch driver is impossible here, so the next person doesn't repeat the
attempt. `FINDINGS.md` is the readable summary; the captures are its raw evidence:

| File                                                             | What it proves                                                                                                                                                                                                                                                            |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `01_init.pcap`                                                   | sensor enumeration + a TLS Alert frame → confirmed this is the **Tudor / TLS 1.2** family.                                                                                                                                                                                |
| `manual_go.pcapng`                                               | a full 5½-minute Windows enroll+unlock: mouse = 36 136 packets, **sensor = 6 control packets, zero bulk** → the biometric I/O is invisible to USB capture on Windows (VBS secure kernel + USBPcap can't see USB-3 bulk). This is the core "give up on captures" evidence. |
| `usb3_test.pcapng`, `vbs_off_test.pcapng`, `02_verify_good.pcap` | follow-up attempts (USB-3 capture armed, VBS disabled) — still no biometric bulk.                                                                                                                                                                                         |

> These are kept because they're the proof behind the strategy pivot. They are safe to
> delete for a leaner repo — the conclusions are all written up in `FINDINGS.md`.

---

## Why we relinked instead of writing a driver

This sensor does **secure enrollment** (SDCP-style pairing; templates live encrypted in
the sensor's own flash and matching happens _in the sensor_). You cannot reconstruct the
host side from USB captures, and on this machine the biometric traffic isn't even
capturable: Windows routes it through the VBS secure kernel and USBPcap can't see USB-3
bulk transfers anyway. Full investigation: `captures/FINDINGS.md`.

That much still holds — **captures** really are a dead end here. What does not hold is
the conclusion we drew from it.

The closest prior project (elitebook840, the neighbouring `06cb:00f0`) tried the
clean-driver route and called it a dead end, and we generalised that to the whole
family. In fact
[vojtapl](https://github.com/vojtapl/synaTudorMiS) had already got a native driver
working on `06cb:00ff` by reverse-engineering the **Windows driver binary** rather than
the wire — the route captures can't reach. So a clean driver was possible; we picked the
relink because we didn't know that, and because the relink gets you there without
reimplementing the protocol at all.

Both routes are real. See [Which path should you take](#which-path-should-you-take).

---

## The blockers we hit, and how they were solved

The interesting part for anyone adapting this. Each was a hard stop; each is now fixed in
`patches/v11.1-00ff.patch` (or in the install scripts).

1. **Windows captures are useless here** → pivoted to the relink. No captures needed; the
   closed driver speaks the protocol for us. _(`captures/FINDINGS.md`)_

2. **The v11.1 DLLs import Windows APIs the older shims lacked.** Built with
   `-DDBGIMPORT=true`, which makes the PE loader log `Unresolved import <name> called!`
   whenever the driver actually calls a missing API. We added stubs only for the ones that
   actually fire (most of the 75 statically-absent imports are CRT noise that's never
   called). _(`docs/V11.1-ADAPTATION.md` has the import-coverage table.)_

3. **Thread creation failing under the sandbox (`EAGAIN`).** glibc gives each thread a
   64 MB arena; with many driver threads that blew past the sandbox's `RLIMIT_DATA`. Fixed
   by raising `SANDBOX_DATA_LIMIT` to 1 GB in `tudor-host/src/sandbox.h`. (An earlier
   retry-loop "fix" was reverted — it masked the real cause.)

4. **Enroll succeeded but identify never matched.** Static RE (`work/re-notes/`) plus a
   cleartext-frame dump showed why: the closed matcher only loads templates that are
   **children of the sensor's common-property user** in its on-flash **DB2** database. Our
   host-side storage created top-level orphan templates that were never loaded. **Fix:**
   route enrollment through the closed adapter's **native WBF storage interface**
   (`SYNA_NATIVE_STORAGE=1`, now the default) so `CommitEnrollment` links the template as a
   DB2 child → it loads into the live matcher → identify matches.

5. **`VerifyFeatureSet` doesn't work on this sensor.** The driver's WINBIO verify path is a
   no-op here. We verify by running **identify** and comparing the returned template GUID
   to the enrolled one.

6. **fprintd got "No devices available" under dbus-broker.** Fedora's default bus
   (dbus-broker) silently drops the launcher's connection the moment it returns a unix file
   descriptor in a D-Bus reply — so the host IPC fd never reached fprintd. **Fix:** the
   launcher serves the fd over its own private root-only AF_UNIX socket via `SCM_RIGHTS`,
   off the bus.

7. **SELinux then blocked that off-bus socket.** The confined `fprintd_t` domain isn't
   allowed to connect to it. **Fix:** the tiny `tudor_fdpass` policy module
   (`scripts/tudor_fdpass.te`) — three `allow` rules, nothing more. SELinux stays
   **enforcing**.

8. **Stale on-sensor templates make verify flaky — and they're hard to clear.** The sensor
   keeps templates in its own flash (DB2), *separate* from fprintd's records under
   `/var/lib/fprint/`. Deleting fingerprints from Linux (the GUI or `fprintd-delete`)
   clears fprintd's view, but there is no verified path that erases the sensor flash, so the
   two **desync** — confirmed by enumerating the sensor's DB2, where a one-finger fprintd
   install was found still holding four orphan template trees from past enroll/delete cycles
   (the matcher ignores them, but they never go away). A **BIOS fingerprint reset** is the
   only proven clean wipe; enroll once cleanly afterwards. Recipes are in
   [`docs/RESET.md`](docs/RESET.md), and `scripts/syna-status.sh` shows both stores at once.
   _(The firmware has a `DB2_FORMAT` opcode (~`0xa4`) that would erase the flash directly,
   but it is destructive and unverified — we deliberately **never** send it.)_

9. **The sensor corrupts replies if it autosuspends.** The no-autosuspend udev rule
   (point above) keeps it awake.

---

## Porting to a different sensor

If your sensor is another Synaptics Tudor PID:

1. **Get your driver DLLs.** Pull `synaWudfBioUsbXXX.dll` + `synaFpAdapterXXX.dll` for your
   machine — `scripts/extract-driver.sh` does this off a mounted Windows install or a vendor
   SoftPaq. Then update the filenames in `scripts/extract-driver.sh`, `scripts/setup.sh` (the
   staging step) and the `download_driver.sh` override it writes.
2. **Set your PID.** `SENSOR_PID` in `scripts/common.sh` covers every script; also update
   the device match in the driver and in `scripts/99-fingerprint-no-autosuspend.rules`.
3. **Run the import loop.** Build with `-DDBGIMPORT=true` (setup.sh already does), run the
   CLI, and add a stub for every `Unresolved import … called!` your driver generation needs
   that ours didn't. The coverage table in `docs/V11.1-ADAPTATION.md` shows the cheap
   implementation for the likely ones.
4. **Expect the storage/matcher issue (point 4 above)** if enroll works but identify
   doesn't — the native-storage routing is the fix, and it's generation-agnostic.
5. **Clear your sensor's DB2 from within the BIOS to reset it before the first clean enroll.**

Most of `patches/v11.1-00ff.patch` is sensor-generation-agnostic (sandbox limits, fd-pass,
native storage, verify-as-identify) and should apply to neighbouring PIDs with only the
DLL-name and PID changes.

---

## Credits & licence

- [Popax21/synaTudor](https://github.com/Popax21/synaTudor) — the relink engine this is
  built on.
- [MarcelineVPQ/elitebook840-fingerprint](https://github.com/MarcelineVPQ/elitebook840-fingerprint)
  — the `06cb:00f0` port whose hp110 patch and udev rule we reuse.

- [vojtapl/synaTudorMiS](https://github.com/vojtapl/synaTudorMiS) — the native
  `synatlsmoc` driver for this same sensor; the path most people should take first.

**Licence: LGPL-2.1-or-later** (see [`LICENSE`](LICENSE)), matching upstream synaTudor,
which `patches/v11.1-00ff.patch` is a derivative of.

This repository does **not** contain the proprietary Synaptics/HP driver binaries. An
earlier revision did, alongside a line telling you not to redistribute them — which
publishing them here contradicted. They are now gone from the working tree and from every
commit in history, and you supply your own from hardware you own. The reasoning, and what
*is* kept from those binaries (export tables, string dumps) and why that is a different
thing, is in [`COPYING.md`](COPYING.md).
