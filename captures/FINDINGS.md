# Synaptics UWP WBDI (06cb:00ff) — reverse-engineering notes

> **OUTCOME (resolved):** the original goal below — a clean from-scratch libfprint driver
> built from USB captures — was abandoned and is a **dead end** for this sensor (firmware
> secure-enrollment + uncapturable biometric traffic, see the STRATEGY PIVOT section). The
> sensor now works on Linux via the **synaTudor relink** instead. See the top-level
> `README.md` and `docs/V11.1-ADAPTATION.md`. This file is kept as the record of *why* the
> capture route failed, so the next person doesn't repeat it; the `.pcap`/`.pcapng` files
> are its raw evidence and are not used by the working driver.

## Goal (ABANDONED — see OUTCOME above)
libfprint userspace driver for Synaptics UWP WBDI fingerprint sensor on HP Spectre x360.
USB ID 06cb:00ff. No existing driver. Modeled on libfprint synaptics driver.

## Reference projects
- elitebook840-fingerprint (06cb:00f0, one PID away): https://github.com/MarcelineVPQ/elitebook840-fingerprint
- libfprint synaptics driver: https://gitlab.freedesktop.org/libfprint/libfprint/-/tree/master/libfprint/drivers/synaptics
- synaTudor (Tudor-family Synaptics, TLS protocol reference): https://github.com/Popax21/synaTudor

## Capture environment (Windows)
- Tools: Wireshark + USBPcap (USB 3.0 capture enabled via `USBPcapCMD -I`).
- Sensor is on USBPcap interface `\\.\USBPcap2`. Address was [3], became [4] after the
  disable/enable in capture 01. **Address changes on re-enumeration**, so all captures use `-A`
  (whole hub) and filter to the sensor in analysis. With `--devices N` an empty 24-byte pcap
  means the address moved — re-check via `USBPcapCMD --extcap-interface \\.\USBPcap2 --extcap-config`.
- Capture cmd pattern (run as Administrator):
  `& "C:\Program Files\USBPcap\USBPcapCMD.exe" -d \\.\USBPcap2 -A -b 67108864 --inject-descriptors -o <file>`

## Confirmed protocol facts (from 01_init.pcap)
- **Communication is TLS-wrapped (TLS 1.2).** Bulk payloads begin with TLS record headers,
  e.g. `15 03 03 00 1a ...` = Alert record (type 0x15), version 0x0303, len 0x1a.
  => This is the Synaptics **Tudor family** protocol. synaTudor + elitebook840 are directly relevant.
- **Transport endpoints:** bulk OUT `0x01`, bulk IN `0x81`. Control ep0 = standard enumeration only.
- Device descriptor decodes correctly: idVendor 0x06cb, idProduct 0x00ff.
- Disable/enable the device produces only a TLS Alert (teardown); the full TLS handshake
  happens lazily on first biometric op => captured in verify/enroll, not in init.

## BLOCKER: biometric path is hidden from USBPcap (VBS / Enhanced Sign-in Security)
- Win32_DeviceGuard: VirtualizationBasedSecurityStatus=2 (running), SecurityServicesRunning=2 (HVCI).
- Proof (manual_go.pcapng, 5.5 min, full pinky enroll + duplicate touch + lock/unlock):
  mouse=36136 pkts, sensor(device 9)=6 control pkts only, ZERO bulk, ZERO TLS.
- The sensor clearly scanned/matched but produced no observable USB traffic in a known-good capture.
- Conclusion: Windows Hello biometric I/O is routed through the VBS secure kernel; USBPcap
  (normal kernel) cannot see it. USBPcap capture on THIS Windows install is a dead end for
  enroll/verify traffic. The only sensor bulk ever captured was a TLS Alert during a device
  teardown (01_init.pcap) which leaks through the normal kernel.
- Ways around it (options below):
  A. Disable VBS/Memory Integrity (+ `bcdedit /set hypervisorlaunchtype off`), reboot, recapture.
     May still be blocked if ESS is enforced independently.
  B. Windows guest VM (VirtualBox already installed) with USB passthrough of 06cb:00ff; sniff on
     the HOST (Linux usbmon). VM guest can't hide traffic from host USB monitor -> bypasses ESS. Most reliable.
  C. Build the driver from references (elitebook840 06cb:00f0 + synaTudor, same Tudor family);
     capture device-specific bits via B only if needed.

## Option A result: VBS disabled, USB3 capture works, but bulk STILL not captured
- Disabled VBS (VirtualizationBasedSecurityStatus=0 confirmed), re-ran USBPcapCMD -I.
- usb3_test.pcapng: sensor enumeration (disable/enable) WAS captured = 6 control packets incl
  device descriptor. But finger touches (verify/enroll) added ZERO bulk frames.
- Conclusion: not VBS/ESS (ESS can't run with VBS off). It's USBPcap's known inability to
  capture USB 3.0 (xHCI) BULK transfers reliably. The sensor's command channel is bulk
  ep 0x01/0x81, so its real traffic is invisible to USBPcap here. DEAD END on Windows/USBPcap.
- NEXT: Option B = capture with Linux usbmon (handles USB3 bulk fine) via a Windows guest VM
  with USB passthrough of 06cb:00ff. Best done on the Linux side (aligns with the migration).
  Also: once a draft libfprint driver exists, usbmon on Linux can capture our own driver's
  traffic + sensor responses directly -- may remove the need for the Windows-driver capture.
- Interface note post-reboot: USBPcap interface<->hub mapping changed (sensor moved cap2->cap1,
  address [6]). Always re-check which USBPcap iface holds the sensor before capturing.

## Earlier gotcha (still true but secondary): USBPcap needs device re-enumeration AFTER capture starts
- USBPcap attaches a filter to the device's driver stack. A device already running when the
  capture starts yields only its (injected) descriptors and NONE of its live traffic.
- Symptom of getting this wrong: pcap contains only frames at t=0.000 (the injected
  descriptors) and nothing after, even though the operation clearly used the sensor.
- FIX: start the capture FIRST, then disable+enable "Synaptics UWP WBDI" in Device Manager
  to re-enumerate it (this hooks USBPcap into its stack), wait ~3s, THEN do the operation.
- Side effect: re-enumeration changes the device's USB address each time -> always use `-A`
  and filter to the sensor in analysis (by address or VID/PID).
- This is why 01_init worked (disable/enable was part of it) but 02/05 first attempts were empty.

## Gotcha: USBPcapCMD will NOT overwrite an existing output file
- If the -o file already exists, USBPcapCMD exits immediately and writes nothing (old file stays).
- Always capture to a fresh filename, or delete the previous file first.
- Sanity check: when capturing, the terminal HANGS (no prompt). If the prompt returns
  immediately, the capture failed (file exists, or other error).

## Gotcha: Windows Hello Face (turned out NOT to apply here)
- Laptop has IR camera but Face is NOT set up (user disabled it; it caused bluescreens).
  Login uses fingerprint. Not the cause of empty captures -- the USBPcap re-enumeration
  issue above was. Kept for reference.

## Old note: Windows Hello Face
- This laptop has an HP IR Camera + Windows Hello Face enrolled. Face unlocks BEFORE the
  fingerprint is read, so lock-screen verifies produce ZERO sensor USB traffic.
- For verify captures: disable "HP IR Camera" (Device Manager > Cameras) and the
  "Facial Recognition (Windows Hello) Software Device", or physically cover the IR camera.
  RE-ENABLE the IR camera when all captures are done.

## STRATEGY PIVOT (important — read this first)
After investigating, a clean from-scratch libfprint driver built from USB captures is NOT
viable for this sensor family — the blocker is firmware-enforced SECURE ENROLLMENT / SDCP
pairing, not USB framing. The closest project (elitebook840, 06cb:00f0) tried exactly that and
called the open driver a dead end. Captures can't provide the secure pairing.

The path that actually works (used by synaTudor + elitebook840): RELINK Synaptics' own driver
binaries to run on Linux, adapted for our 06cb:00ff. So:
- We do NOT need more Windows USB captures. (01_init.pcap already confirmed Tudor/TLS family.)
- Key asset SAVED: ../hp-driver/ contains the Windows driver binaries from this machine:
  synaWudfBioUsb111.dll (the one synaTudor relinks), synaFpAdapter111.dll, INF, cat. Version 11.1.
  (elitebook840's patch is for v11.0 — expect minor offset differences.)

## Linux next steps (the real plan)
1. Clone synaTudor (https://github.com/Popax21/synaTudor) and elitebook840-fingerprint.
2. Use our ../hp-driver/ binaries (v11.1) with the synaTudor relink shim (libtudor).
   The elitebook840 synaTudor-hp110.patch is the closest starting point; adapt for v11.1 + 00ff.
3. Add the no-autosuspend udev rule (from elitebook840) — these sensors need it on Linux.
4. Expect to hit the secure-DB enrollment issue elitebook840 got stuck on (~90%): a stale
   on-sensor record (NumCurrentUsers=1, error 118) causing an init loop. NOTE: this sensor
   currently has Windows enrollments on it — those on-sensor records may be exactly what
   triggers the loop. Consider clearing on-sensor enrollments (via Windows Settings, remove all
   fingerprints) BEFORE the reset/migration to start Linux from a clean sensor DB.
5. usbmon (Linux) is the capture tool to use if debugging is needed — it handles USB3 bulk
   (which USBPcap on Windows could not).

## Why Windows capture was abandoned (summary)
USBPcap cannot reliably capture USB 3.0 (xHCI) BULK transfers, and the sensor's command channel
is bulk ep 0x01/0x81. Even with VBS disabled and USB3 capture armed (-I), only enumeration
(control) was captured, never biometric bulk. See sections below for the full investigation.

## Capture plan (order)
1. [DONE] 01_init.pcap        — disable/enable device; enumeration + init
2. 02_verify_good.pcap        — sign in with ENROLLED finger x3-4 (full TLS handshake expected here)
3. 03_verify_bad.pcap         — touch with NON-enrolled finger x3-4 (failure response)
4. 04_delete_all.pcap         — remove all fingerprints in Settings (delete flow; resets DB to empty)
5. 05_enroll.pcap             — enroll one finger from empty (cleanest enrollment)
6. 06_enroll_second.pcap      — enroll a second finger (slot/template indexing)

## Analysis cheatsheet (tshark)
- Filter to sensor:  `-Y "usb.device_address == 3"`
- Show payloads:     `-T fields -e frame.number -e usb.endpoint_address -e usb.transfer_type -e usb.data_len -e usb.capdata`
- transfer_type: 0x02=control, 0x03=bulk. endpoint: 0x01 OUT, 0x81 IN.
- TLS record types: 0x16=Handshake, 0x17=AppData, 0x15=Alert, 0x14=ChangeCipherSpec.

## TODO (analysis phase, on Linux)
- [ ] Locate full TLS handshake (0x16 records) in verify capture; identify cipher suite / key exchange.
- [ ] Determine pairing/host-key mechanism (synaTudor uses a host secret / pairing data).
- [ ] Decode application-layer command framing inside TLS AppData (0x17 records).
- [ ] Diff verify_good vs verify_bad to find match-result code.
