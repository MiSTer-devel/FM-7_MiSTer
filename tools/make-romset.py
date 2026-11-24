#!/usr/bin/env python3
"""Build a system ROM set file (boot1.rom) for the FM-7 core.

The core pages one set out of SDRAM into block RAM at reset; rtl/ROMLOAD.v
reads it with the layout below and docs/ROMSETS.md documents it for users.
All three have to agree, so the offsets live here as one table.

  offset   size    ROM    what
  $00000   32768   m151   main ROM / F-BASIC        ($8000-$FBFF, 31744 used)
  $08000    2048   m152   boot ROM, 4 banks of 512
  $08800    2048   m153   character generator
  $09000    8192   m154   sub-system monitor
                          -- 45056 bytes, padded to a 65536-byte stride

Usage:
  tools/make-romset.py -o releases/boot1.rom \\
      --set fbasic300.rom,TL11_11_M152.rom,subsys_m153.rom,subsys_m154.rom \\
      --set secoinsa_fbasic.rom,TL11_11_M152.rom,secoinsa_cg.rom,subsys_m154.rom

Each --set is four comma-separated paths in m151,m152,m153,m154 order,
resolved against --romdir (default rtl/roms). A short file is padded with
$FF; a long one is an error rather than a silent truncation.

--fm8 PATH appends an FM-8 set built from MAME's fm8.zip (or a directory
holding the same four files). The core's Machine = FM-8 pages in set 2, so
give it after exactly two --set arguments:

  tools/make-romset.py -o releases/boot1.rom \\
      --set ... --set ... --fm8 fm8.zip

  fbasic10.rom  (31744)  -> m151
  bootbas8.rom  (512)    -> m152 bank 0 (BASIC)
  bootdos8.rom  (512)    -> m152 bank 2 (5" DOS). The FM-8's SM11-14 boot ROM
                            is BASIC / 32K bubble / 5" DOS / debug; banks 1
                            and 3 were not dumped and are left $FF.
  subsys_8.rom  (10240)  -> m153 (first 2 KB, the font) + m154 (the rest)

Both boot dumps end in $FF $FF where the reset vector belongs, so every bank
gets $FE00 written at $1FE -- what CSP does on load (mainmem_utils.cpp,
`p[0x1fe] = 0xfe`) for the same dumps.
"""
import argparse, io, os, re, sys, zipfile

STRIDE = 0x10000
REGIONS = [("m151", 0x00000, 32768),
           ("m152", 0x08000,  2048),
           ("m153", 0x08800,  2048),
           ("m154", 0x09000,  8192)]

def load(path):
    """Read a ROM image. Accepts a raw binary or a `.mem` file -- the hex-text
    form $readmemh eats, one byte per line -- because rtl/roms/ carries some
    ROMs only in that form (subsys_m153/m154 are split out of subsys_c.rom as
    .mem and never existed as separate binaries)."""
    raw = open(path, "rb").read()
    if path.endswith(".mem") or path.endswith(".hex"):
        txt = raw.decode("ascii", "replace")
        toks = re.findall(r"[0-9A-Fa-f]{2}", txt)
        return bytes(int(t, 16) for t in toks)
    return raw


FM8_FILES = {"fbasic10.rom": 31744, "bootbas8.rom": 512,
             "bootdos8.rom": 512, "subsys_8.rom": 10240}

def fm8_set(path):
    """The four regions of an FM-8 set, from fm8.zip or a directory."""
    if os.path.isdir(path):
        get = lambda n: open(os.path.join(path, n), "rb").read()
    else:
        z = zipfile.ZipFile(path)
        names = {os.path.basename(n).lower(): n for n in z.namelist()}
        get = lambda n: z.read(names[n])
    roms = {}
    for name, size in FM8_FILES.items():
        try:
            data = get(name)
        except (KeyError, FileNotFoundError):
            sys.exit(f"--fm8 {path}: {name} missing")
        if len(data) != size:
            sys.exit(f"--fm8 {path}: {name} is {len(data)} B, expected {size}")
        roms[name] = data
    def bank(data):
        b = bytearray(data if data else b"\xff" * 512)
        b[0x1fe:0x200] = b"\xfe\x00"
        return bytes(b)
    m152 = (bank(roms["bootbas8.rom"]) + bank(None) +
            bank(roms["bootdos8.rom"]) + bank(None))
    sub = roms["subsys_8.rom"]
    return [("fbasic10.rom", roms["fbasic10.rom"]),
            ("bootbas8+bootdos8", m152),
            ("subsys_8.rom[0:2K]", sub[:0x800]),
            ("subsys_8.rom[2K:]", sub[0x800:])]


def place(n, sources):
    """One set's 64 KB stride from (label, bytes) pairs in region order."""
    buf = bytearray(b"\xff" * STRIDE)
    for (name, off, size), (label, data) in zip(REGIONS, sources):
        if len(data) > size:
            sys.exit(f"set {n} {name}: {label} is {len(data)} B, "
                     f"region holds {size}")
        buf[off:off + len(data)] = data
        print(f"  set {n} {name}  {len(data):6} B  <- {label}"
              + ("" if len(data) == size else f"  (padded to {size})"))
    return buf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--romdir", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "rtl", "roms"))
    ap.add_argument("--set", action="append", required=True,
                    help="m151,m152,m153,m154 (comma separated)")
    ap.add_argument("--fm8", help="fm8.zip or directory; becomes the next set")
    a = ap.parse_args()
    if a.fm8 and len(a.set) != 2:
        sys.exit("--fm8 must follow exactly two --set arguments: "
                 "the core reads the FM-8 from set 2")

    blob = bytearray()
    for n, spec in enumerate(a.set):
        paths = [p.strip() for p in spec.split(",")]
        if len(paths) != 4:
            sys.exit(f"set {n}: expected 4 paths, got {len(paths)}")
        full = [p if os.path.isabs(p) else os.path.join(a.romdir, p)
                for p in paths]
        blob += place(n, [(os.path.basename(f), load(f)) for f in full])
    if a.fm8:
        blob += place(len(a.set), fm8_set(a.fm8))

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    open(a.out, "wb").write(blob)
    print(f"wrote {a.out}: {len(blob)} B, {len(blob) // STRIDE} set(s)")

if __name__ == "__main__":
    main()
