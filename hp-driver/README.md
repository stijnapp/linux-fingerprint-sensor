# `hp-driver/` — the closed Synaptics driver (NOT included)

The relink path loads two **proprietary Synaptics/HP Windows driver DLLs**. They are
deliberately **not committed to this repository** — they are Synaptics' copyrighted
binaries, distributed by HP under a licence that does not permit redistribution.

You supply your own copy, from hardware you own. `scripts/extract-driver.sh` does it
for you; see [Getting the DLLs](#getting-the-dlls).

## What goes here

| File | Role | SHA-256 |
| --- | --- | --- |
| `synaWudfBioUsb111.dll` | the UMDF USB driver — contains the matcher and the DB2 template logic | `3974b4ac7fddb0932877a16fe9919bdea5a6dd4ed889e233771f9e33e6357e19` |
| `synaFpAdapter111.dll` | thin WBF adapter shim (the `Wbio*Interface` surface libtudor drives) | `edaf4ebc0b03780de2ac0be9350cb99ace14350da45bcb3dd787d56631b6b25a` |

Those hashes are the exact build this repository was developed and tested against:

```
Provider:   Synaptics Incorporated
DriverVer:  07/05/2022, 6.0.62.1111   ("v11.1" / the "111" generation)
INF:        synawudfbiousbuwp.inf     (CatalogFile=synaUMDF.cat)
Covers:     USB\VID_06CB&PID_{00C9,00D1,00E7,00FF,0124,0169}
```

A different build of the same driver generation will very likely work; the PE loader
resolves entry points by export name, not by version. If your hashes differ, that is
not an error — it just means this repo's import-coverage table
(`docs/V11.1-ADAPTATION.md`) was written against a slightly different binary, so
re-run the `-DDBGIMPORT=true` loop.

## Getting the DLLs

`scripts/extract-driver.sh` handles both routes and verifies what it finds:

```sh
# from a Windows install on this machine (mounted, or it will tell you how)
./scripts/extract-driver.sh --from-windows /run/media/$USER/Windows

# from an HP SoftPaq you downloaded from support.hp.com (needs 7z or cabextract)
./scripts/extract-driver.sh --from-softpaq ~/Downloads/sp1xxxxx.exe
```

Either way the two DLLs land in this directory and `scripts/setup.sh` picks them up.

**Route 1 — your own Windows partition.** The files live at:

```
<win>/Windows/System32/drivers/UMDF/synaWudfBioUsb111.dll
<win>/Windows/System32/synaFpAdapter111.dll
```

and a pristine copy of both is kept in the driver store, which is what the script
prefers because it is the as-shipped package:

```
<win>/Windows/System32/DriverStore/FileRepository/synawudfbiousbuwp.inf_amd64_*/
```

**Route 2 — the HP SoftPaq.** Look up your machine on support.hp.com, Software &
Drivers → Driver-Keyboard, Mouse and Input Devices → "Synaptics Fingerprint Sensor
Driver". The `.exe` is a self-extracting archive; `7z x` or `cabextract` opens it
without running it.

## Why this repo does not ship them

An earlier revision of this repository committed these binaries, together with a
README line saying "do not redistribute them" — which the act of publishing them on
GitHub contradicted. They have since been removed from the working tree **and from
every commit in history** (`git filter-repo`). If you cloned this repo before that
rewrite, your clone still contains them; re-clone.

The interoperability work built on top of them — the patch, the notes, the import
tables — is ours and stays. Reverse-engineering an interface for interoperability is
what the rest of this repo documents; redistributing the vendor's binary is a
different act, and not one this repo needs to perform.
