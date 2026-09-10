# Resetting, removing, and re-enrolling

There are **two separate stores** of fingerprint data, and almost every confusing
symptom with this sensor comes from forgetting that:

| | Where | Cleared by | Survives |
| --- | --- | --- | --- |
| **Host records** | `/var/lib/fprint/<user>/` + `~/.tudor-store` | `fprintd-delete`, the GUI, `uninstall.sh --purge` | OS reinstall? no |
| **Sensor templates** | the reader's own flash (**DB2**) | **BIOS fingerprint reset only** | OS reinstall, driver removal, `fprintd-delete`, everything on this page except the BIOS |

Deleting a finger on Linux clears the host side and leaves the sensor side untouched.
The two then disagree: the GUI says "no fingerprints", the sensor is still holding
templates. Confirmed by enumerating DB2 — a one-finger install was found still
carrying **four** orphan template trees from earlier enroll/delete cycles.

Orphans are inert (only children of the common-property user get loaded into the live
matcher, so they cause no false matches) but they never go away, and enough churn
makes matching flaky.

## See which of the two you are looking at

```sh
./scripts/syna-status.sh            # host side, no root needed
sudo ./scripts/syna-status.sh --deep  # + enumerate the sensor's flash
```

## The recipes

### Re-enroll a finger (matching got flaky)

```sh
fprintd-delete "$USER"     # host side
fprintd-enroll "$USER"     # enroll again
fprintd-verify
```

Try this first. If it is still flaky, the sensor flash has accumulated orphans — do
the full reset below.

### Full reset — the only clean wipe

1. `fprintd-delete "$USER"` (clear the host side first, so the two stores end up
   agreeing rather than desyncing in the other direction).
2. Reboot into the **BIOS/UEFI setup** (on the HP Spectre x360, tap `F10` at power-on).
3. Find **Security ▸ Fingerprint Reset**, or "Reset Fingerprint Data" / "Clear
   Fingerprint Data" depending on firmware version. Confirm it.
4. Boot back into Linux and enroll **once**, cleanly:
   ```sh
   fprintd-enroll "$USER" && fprintd-verify
   ```

Enrolling once after a reset is the configuration this driver is known-good in.
Repeated enroll/delete cycles without a BIOS reset are what produce the orphans.

### Remove the driver entirely

```sh
sudo ./scripts/uninstall.sh --dry-run   # look first
sudo ./scripts/uninstall.sh             # PAM is disarmed before anything else
sudo ./scripts/uninstall.sh --purge     # also delete host-side templates
```

Your password stays a valid login throughout — there is no point at which the
uninstall can lock you out.

## Why there is no `wipe-sensor.sh`

The firmware does have a `DB2_FORMAT` opcode (≈`0xa4`) that would erase the flash
directly. This repo deliberately **never sends it**:

- it is destructive and, on this sensor, unverified — nobody has confirmed what state
  it leaves the pairing data in;
- vojtapl's notes on the same family warn that formatting the sensor host partition
  can lose the Windows pairing data with it;
- the BIOS path does the same job with the vendor's own code and a confirmation
  prompt.

The CLI's `w` (wipe) menu entry goes through the closed driver's own storage
interface and clears templates it knows about — it is not `DB2_FORMAT` and it does
not reach the orphans.

## If you dual-boot Windows

Enrollments are tied to a set of pairing data. Pairing the sensor to a Linux driver
invalidates the Windows Hello enrollments (and vice versa). Remove your Hello
fingerprints in Windows Settings **before** migrating, or expect to re-enroll on
whichever side you used last. A BIOS reset clears both at once, which is the
predictable way out if they get tangled.
