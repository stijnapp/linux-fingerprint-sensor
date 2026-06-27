# Linux fingerprint login for the Synaptics "Tudor" sensor `06cb:00ff`

A working **fprintd** backend for the Synaptics fingerprint reader **USB ID `06cb:00ff`**
(Synaptics UWP WBDI / "Tudor" family, HP driver **v11.1**), as found in the HP Spectre
x360. Tested on **Fedora Workstation 44**.

**Status: working.** Enroll, verify, **GDM graphical login**, lock screen, and **`sudo`**
all authenticate by fingerprint, with the password always available as a fallback (you
cannot get locked out).

This is **not** a from-scratch libfprint driver. A clean driver is a dead end for this
sensor family (the enrollment is secured in firmware — see
[Why not a clean driver](#why-not-a-clean-driver-the-short-version)). Instead we **relink
Synaptics' own closed Windows driver DLLs** to run on Linux, using
[Popax21/synaTudor](https://github.com/Popax21/synaTudor), adapted for our specific sensor
and driver version.

> If you have a **different Synaptics Tudor sensor** (e.g. `06cb:00be`, `06cb:00f0`, or
> another HP/Lenovo PID), this repo is meant to be a usable map of the whole adaptation —
> see [Porting to a different sensor](#porting-to-a-different-sensor).

---

## Quick start (this exact sensor, Fedora)

```sh
# 0. build deps (once)
sudo dnf install -y meson ninja-build gcc pkgconf-pkg-config openssl-devel libusb1-devel

# 1. build the relinked driver (no root, no sensor needed — it's offline)
./scripts/setup.sh

# 2. deploy it system-wide as an fprintd backend (needs root)
sudo ./scripts/install.sh

# 3. enroll — the normal Fedora way is the GUI:
#      Settings ▸ Users ▸ Fingerprint Login   (you choose which finger; the same
#      panel also removes enrolled fingers). Or on the command line:
#      fprintd-enroll        # swipe through the stages until "enroll-completed"
#      fprintd-verify        # confirm it matches

# 4. test: lock the screen (Super+L) and unlock by fingerprint, or:  sudo -k; sudo true
```

Reinstalling from scratch (e.g. on a fresh OS install) is just **`setup.sh` then
`install.sh`**, then enroll.

> **Caveat — resetting templates does not reach the sensor.** Removing fingerprints (in the
> GUI or with `fprintd-delete`) clears *fprintd's* records, but the sensor keeps its
> templates in its own flash (DB2) and there is **no verified path that erases that flash
> from Linux**, so the two **desync**: the GUI shows "no fingerprints" while stale templates
> stay on the sensor. (Confirmed by reading the sensor's DB2 — a one-finger install was
> found still holding four orphan template trees from past enroll/delete cycles. They don't
> cause false matches, since only the live finger is loaded into the matcher, but they never
> go away.) The only **proven** clean wipe is a **BIOS fingerprint reset**; do that and
> enroll once if matching gets flaky. See
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
| `scripts/`    | everything you run — build, deploy, debug, and the support files they install                      |
| `patches/`    | **our** changes to synaTudor, as a single git patch (the real source of our work)                  |
| `hp-driver/`  | the closed HP **v11.1** Windows driver binaries extracted from this laptop                         |
| `references/` | upstream projects as git submodules (synaTudor + the elitebook840 port)                            |
| `work/`       | build tree + reverse-engineering notes (generated/scratch; not the source of truth)                |
| `docs/`       | the adaptation write-up (`V11.1-ADAPTATION.md`)                                                    |
| `captures/`   | Windows USB captures + `FINDINGS.md` — the dead-end investigation that made us pivot to the relink |
| `.gitmodules` | declares the two submodules under `references/`                                                    |

### `scripts/` — the things you run, and the support files they install

| File                                  | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `setup.sh`                            | **build** (no root). Clones the pinned synaTudor base, applies the elitebook hp110 patch then **our** `v11.1-00ff.patch`, stages the HP v11.1 DLLs, runs `meson`/`ninja`. Output: `work/synaTudor/build/`.                                                                                                                                                                                                                                                                                                                |
| `install.sh`                          | **deploy** (root). `meson install` (binaries → `/sbin/tudor`, the TOD driver, udev rule, systemd unit, D-Bus files) + installs the autosuspend rule + the SELinux module + enables fingerprint in PAM. Idempotent.                                                                                                                                                                                                                                                                                                        |
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

### `hp-driver/` — the closed binaries (kept, load-bearing)

The genuine Synaptics v11.1 ("111") Windows driver pulled off this laptop. `setup.sh`
embeds the two DLLs into the build (renamed to the `104` names libtudor expects).

| File                                    | What                                                                                      |
| --------------------------------------- | ----------------------------------------------------------------------------------------- |
| `synaWudfBioUsb111.dll`                 | the UMDF USB driver — **contains the matcher and the DB2 template logic**                 |
| `synaFpAdapter111.dll`                  | thin WBF adapter shim (the `Wbio*Interface` surface libtudor drives)                      |
| `synawudfbiousbuwp.inf`, `synaUMDF.cat` | Windows install manifest + catalog signature (kept for provenance; not used by the build) |

### `references/` — upstream, as submodules (don't edit)

| Submodule                  | Why it's here                                                                                                                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `synaTudor`                | the relink engine itself; pinned at commit `31dfdb0` (the base our patches target).                                                                                                                  |
| `elitebook840-fingerprint` | a port of synaTudor to the neighbouring `06cb:00f0` sensor. We reuse its `synaTudor-hp110.patch` wholesale (the Windows-API shims the newer HP driver generation needs) and its no-autosuspend rule. |

### `work/` — generated, not source

| Path              | What                                                                                                                                                                                                                                                                                                                                                        |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `work/synaTudor/` | a throwaway clone that `setup.sh` builds in (base + patches applied). The live build is `work/synaTudor/build/`. Reproducible from scratch — safe to delete and rebuild.                                                                                                                                                                                    |
| `work/re-notes/`  | static reverse-engineering notes that cracked the storage bug: `template-load-chain.md` (how the closed driver loads templates into the matcher, with the decoded DB2 opcode stream), DLL `*.exports.txt` / `*.strings.txt`, and `bio.disasm.txt` (a 12 MB objdump of the driver — regenerate-able, kept because grepping it was how we found the opcodes). |

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

## Why not a clean driver (the short version)

This sensor does **secure enrollment** (SDCP-style pairing; templates live encrypted in
the sensor's own flash and matching happens _in the sensor_). You cannot reconstruct the
host side from USB captures, and on this machine the biometric traffic isn't even
capturable: Windows routes it through the VBS secure kernel and USBPcap can't see USB-3
bulk transfers anyway. The closest prior project (elitebook840, the neighbouring
`06cb:00f0`) tried the clean-driver route and called it a dead end. So we relink the real
driver instead. Full investigation: `captures/FINDINGS.md`.

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
   only proven clean wipe; enroll once cleanly afterwards.
   _(The firmware has a `DB2_FORMAT` opcode (~`0xa4`) that would erase the flash directly,
   but it is destructive and unverified — we deliberately **never** send it.)_

9. **The sensor corrupts replies if it autosuspends.** The no-autosuspend udev rule
   (point above) keeps it awake.

---

## Porting to a different sensor

If your sensor is another Synaptics Tudor PID:

1. **Get your driver DLLs.** Pull `synaWudfBioUsbXXX.dll` + `synaFpAdapterXXX.dll` for your
   machine (off a Windows install, or the vendor SoftPaq). Drop them in `hp-driver/` and
   update the filenames in `scripts/setup.sh` (the staging step) and the `download_driver.sh`
   override it writes.
2. **Set your PID.** It's `-P00ff` in `syna-cli.sh` and the device match in the driver/udev
   rule — change `00ff` to yours.
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

This repository contains **proprietary Synaptics/HP driver binaries** (`hp-driver/`) under
`hp-driver/synawudfbiousbuwp.inf`'s original licence — they are included only so this
specific machine's owner can run their own hardware on Linux. Do not redistribute them.
The scripts, patches, and notes here are offered in the same spirit as the upstream
projects (see their licences).
