# Static RE: where the closed driver loads templates into the matcher

Date: 2026-06-17. Tooling: objdump (pei-x86-64), strings. Both DLLs = HP v11.1.
Raw artifacts in this dir: `bio.disasm.txt` (12M objdump of synaWudfBioUsb111 .text),
`*.strings.txt`, `*.exports.txt`.

## DLL roles (confirmed via exports)
- **synaFpAdapter111.dll** = thin WBF shim. Exports: `WbioQueryEngineInterface`,
  `WbioQuerySensorInterface`, `WbioQueryStorageInterface`. This is the surface
  libtudor drives.
- **synaWudfBioUsb111.dll** = UMDF USB driver (`FxDriverEntryUm`). **Contains the
  matcher** ("Mis Matcher Module") AND the DB2 / template-cache logic.

## The template-load chain (all inside the USB driver, C++ virtual methods)
String evidence (synaWudfBioUsb111.strings.txt):
```
tudorCmdGetDbInfo  ->  tudorCmdGetObjectList
  -> CEisMisEIV::RetrieveTemplatesFromFlash / RetrieveTemplatesFromCache
  -> CBiometricDevice::OnSetTemplateList
  -> _updateEnrollmentCache
```
This is what populates the sensor's **live matcher set** from DB2 flash.
Failure strings exist for each step ("Call of tudorCmdGetObjectList() failed." etc.).

These are **vtable-dispatched** (no direct `call <addr>` xrefs in .text) — invoked
internally during the device lifecycle, NOT through the host-facing WBF vtable.

## Where it fires: OnPrepareHardware / OnD0Entry (device power-up)
- WBF method table present: `CBiometricDeviceUSB::OnPrepareHardware`,
  `CBiometricDevice::PrepareHardware`, `OnD0Entry`, ... `OnSetTemplateList`.
- Matches the elitebook840 Wireshark capture of REAL Windows: DB2 GET_DB_INFO ->
  GET_OBJECT_LIST issued at OnPrepareHardware.

## KEY CORRECTION to prior root-cause note
libtudor's WDF shim **does fire the full bring-up** during tudor_open:
`src/winapi/wdf/device.c:185-188`:
```
EvtDevicePrepareHardware -> EvtDeviceD0Entry
  -> EvtDeviceD0EntryPostInterruptsEnabled -> EvtDeviceSelfManagedIoInit
```
So OnPrepareHardware/OnD0Entry ARE executed. The load chain SHOULD run.

Our earlier "no DB2 enumeration at open" was inferred from the `[DEVCTRL]` log,
which sits at `tudor_devctrl` (device.c:83) = the FpAdapter->USB **IOCTL (0x44xxxx)**
boundary. The DB2 ops at OnPrepareHardware are issued **internally** by the USB
driver and sent TLS-wrapped via `WdfUsbPipeWrite` (winapi/wdf/usb.c) — they never
traverse a 0x44xxxx DEVCTRL. **=> existing logging is BLIND to them. The claim that
no DB2 load happens at open is UNPROVEN.**

## Instrumentation added (hardware-free code change, build OK)
The closed driver has no direct OpenSSL — ALL its crypto goes through our BCrypt
shim (`KDF_TLS_PRF` + GCM AuthTagLength => it does its own TLS via BCrypt). So the
cleartext VCSFW command stream passes through `BCryptEncrypt` (in=outbound frame) /
`BCryptDecrypt` (out=inbound frame).

Added `bc_plaintext_peek()` in `src/winapi/bcrypt/bcrypt.c`, logging at INFO:
- `[CRYPTO TX] algo=<name> size=.. : <first 48 bytes>`  (outbound commands)
- `[CRYPTO RX] algo=<name> size=.. : <first 48 bytes>`  (sensor responses)

## Next: run enroll+open and read the [CRYPTO TX/RX] stream at open
Two possible outcomes:
- (A) DB2 enumeration DOES fire at open but returns empty/errors (cf. elitebook's
  `GetNextEnrollment(118)` choke) -> the load is attempted but failing -> fix the
  failing sub-call.
- (B) DB2 enumeration does NOT fire at open -> OnPrepareHardware short-circuits
  before the load (gated by a capability/secure-state flag) -> find & satisfy gate.

GET_DB_INFO response is recognizable by its known 8-byte count (we already decoded
0x44202c <- count). Opcode numeric values not yet extracted (logged as trace-only
strings in the DLL; the cleartext frames will reveal them empirically).

## CONFIRMED on the wire (2026-06-17 [CRYPTO TX/RX] capture at open)
Open-time matcher load, decoded (opcodes: 9e=GET_DB_INFO 9f=GET_OBJECT_LIST
a0=GET_OBJECT_INFO a1=GET_OBJECT_DATA; 9f byte1 = list type 01=users 02=templates
03=children-of-parent):
```
9f02 ff..ff      -> 5 templates (ours): b78a276d 5de9f8bc 11bb188a e073f87a 191436fc
9f03 <each>      -> 0 children (top-level orphans)
9f01 00..00      -> 6 users: 6986d487 2fa96917 71dec9c0 d3ea1db4 77ff568c 8809a8d3
a001 <each user> -> info; all "..0101.." EXCEPT 8809a8d3 -> "..0100.."
9f03 8809a8d3    -> child template 78621bb5      (ONLY the common-prop user is descended)
a003 78621bb5    -> info: parent=8809a8d3
a103 78621bb5    -> 30-byte descriptor LOADED INTO MATCHER
```
=> matcher live-set = children of common-prop user 8809a8d3 ONLY = {78621bb5}.
Our 5 enrolled templates are top-level orphans -> never loaded -> identify NO_RESULTS.
Identify pipeline itself works (86/87/80/81 capture, 9d submit, 99->0905 no-match).

## Storage is host-only (storage.c) — DB2 is engine-only
tudor_storage_adapter AddRecord/DeleteRecord/wipe edit only device->records_head;
EraseDatabase=NOTIMPL. CLI `w` and ~/.tudor-store do NOT touch DB2. All DB2 objects are
created by the closed engine at CommitEnrollment. => cannot clear DB2 orphans from host.

## DB2 commands exist in firmware (synaWudfBioUsb111 strings)
VCSFW_CMD_DB2_FORMAT, _DELETE_OBJECT, _WRITE_OBJECT, _CLEANUP, _GET_DB_INFO/_LIST/_INFO/
_DATA; stiTudorDatabaseErase, vfmStgErase, CBiometricDevice::OnEraseDatabase.
GET opcodes 9e/9f/a0/a1 match string order => FORMAT ~0xa4 (UNVERIFIED — pin from disasm
before sending; destructive).
