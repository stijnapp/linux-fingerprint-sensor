# Licensing

**Everything in this repository is LGPL-2.1-or-later**, matching
[Popax21/synaTudor](https://github.com/Popax21/synaTudor), which it builds on.
`patches/v11.1-00ff.patch` is a diff against synaTudor's LGPL sources and is
therefore a derivative work of it; the scripts and documentation are offered under
the same terms so the whole tree is consistent. Full text in [`LICENSE`](LICENSE).

## What is deliberately NOT here

The closed **Synaptics/HP Windows driver DLLs**. They are Synaptics' copyrighted
binaries, redistributed by HP under a licence that does not permit further
redistribution, so this repository does not carry them — you supply your own from
hardware you own (`scripts/extract-driver.sh`, `hp-driver/README.md`).

An earlier revision of this repo did commit them. They have been removed from the
working tree and from **every commit in history**. Note the limits of that: a rewrite
does not reach clones people already made, forks, or objects GitHub may still serve
by SHA until it garbage-collects. It closes the front door, which is the part that
was actually wrong.

## What is here, and why that is a different thing

`work/re-notes/` holds export tables and string dumps taken from those binaries, and
`docs/V11.1-ADAPTATION.md` an import-coverage analysis derived from them. These are
interface facts gathered to make independently-written software interoperate with the
hardware — the activity the repo exists to document. The full 12 MB disassembly that
an earlier revision committed has been dropped: unlike an export list, it reproduces
the program's logic rather than describing its interface, and it is regenerable in
one command by anyone holding their own copy of the DLL
(`objdump -d hp-driver/synaWudfBioUsb111.dll`).

The captures in `captures/` are recordings of USB traffic from the author's own
machine.
