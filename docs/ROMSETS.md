# System ROM sets

The FM-7's main ROM, boot ROM, character generator and sub-system monitor can
be replaced at run time from a file on the SD card, so one `.rbf` can be more
than one machine. This is how the Spanish **Secoinsa FM-7** is supported.

## The file

`boot1.rom`, in the core's directory next to the `.rbf`. MiSTer's main firmware
uploads `boot0.rom`..`boot3.rom` at core start with `ioctl_index = N << 6`
(`Main_MiSTer/user_io.cpp`, "check for multipart rom"), so:

| file | ioctl index | what this core does with it |
|---|---|---|
| `boot.rom` / `boot0.rom` | 0 | the 128 KB kanji ROM, as before |
| `boot1.rom` | 64 | the system ROM sets |

**It is optional.** With no `boot1.rom` the machine runs the ROMs built into
the `.rbf` and behaves exactly as it did before this existed. Nothing about an
existing install changes.

## Layout

Each set is 45056 bytes at a **65536-byte stride**. Set 0 is selected by the
`System ROM` OSD row's first entry, set 1 by its second, and **set 2 by
`Machine` = FM-8**, whatever `System ROM` says.

| offset | size | ROM | what |
|---|---|---|---|
| `$00000` | 32768 | `m151` | main ROM / F-BASIC, `$8000-$FBFF` (31744 used) |
| `$08000` | 2048 | `m152` | boot ROM, 4 banks of 512 |
| `$08800` | 2048 | `m153` | character generator |
| `$09000` | 8192 | `m154` | sub-system monitor |
| `$0B000` | — | | pad to `$10000`, next set follows |

`rtl/ROMLOAD.v` and `tools/make-romset.py` both encode this table. Changing one
means changing all three.

Build a file with:

```sh
tools/make-romset.py -o releases/boot1.rom \
  --set fbasic300.rom,TL11_11_M152.rom.mem,subsys_m153.rom.mem,subsys_m154.rom.mem \
  --set secoinsa_fbasic.rom,TL11_11_M152.rom.mem,secoinsa_cg.rom,subsys_m154.rom.mem
```

For the FM-8, add `--fm8 fm8.zip` (MAME's set) after the two `--set`
arguments; see [The FM-8](#the-fm-8) for what it does to the files.

Paths resolve against `rtl/roms/`; raw binaries and `$readmemh` `.mem` text are
both accepted, because some of these ROMs only exist in the repo as `.mem`.

## How it is applied

`ROMLOAD.v` copies the selected set out of SDRAM into the four block RAMs while
the machine is held in reset, then releases it. Changing the OSD row resets the
machine — swapping the BASIC ROM under a running interpreter is not a thing.

A file too short to hold a full set is ignored entirely (the baked ROMs stay);
a file without set 1 or set 2 makes that selection fall back to set 0 rather
than page in whatever else is in SDRAM. So an FM-8 with a two-set file is the
FM-8's hardware running the FM-7's ROMs: it boots F-BASIC 3.0.

**The reverse is not safe: a three-set file breaks every core before the
FM-8 build.** Those cores keep 17 bits of the download address, so set 2
lands on set 0 and the FM-7 boots *FUJITSU MICRO 8 BASIC* (seen on hardware
with `FM-7_20261102.rbf`). A three-set `boot1.rom` must only ever ship
alongside a core that has the FM-8.

The loader holds off while any other ioctl download is writing SDRAM (a tape
mounted by an MGL at core start, for one). `sdram.sv` has a single pending
slot, and a write that lands while a ROMLOAD read is pending drops the read
and hands the loader the write's `ready` instead -- a garbage byte in the ROM.

**Why SDRAM and not a second set of block RAMs.** `m151` is 32768 deep and
costs 32 M10K blocks on its own; a duplicate plus a duplicate character
generator is 34 of the 37 free blocks recorded in `TODO.md`'s FPGA fit section.
Staging in SDRAM costs **zero** blocks — measured, see that section — and the
SDRAM sets live at `$420000`, just above the kanji ROM, with ~30 MB spare.

The CPU cannot execute from SDRAM: it fetches every bus cycle, and the kanji
ROM was the only ROM that could move off-chip because it is read through a slow
I/O window that prefetches. So this is a copy into block RAM, not a redirect.

## The Secoinsa FM-7

The Spanish licensee's machine. Measured against the Japanese set, byte for
byte — **only two of the four ROMs actually differ**:

| ROM | Secoinsa vs Japanese |
|---|---|
| `m151` F-BASIC | **differs** — 430 bytes of 31744, in 24 clusters |
| `m153` character generator | **differs** — Latin glyphs where Japanese has katakana: `$A1` is `Ñ`, `$A2` is `Ç`, `$BF` is `¿` |
| `m152` boot ROM | identical |
| `m154` sub monitor | identical |

Derived from a three-file dump, kept for provenance as
`rtl/roms/FM7SecoinsaROMs.zip` (`FM7Secoinsa_8435.BIN`, `_8449.BIN`,
`_GPU.BIN`):

- `_8449.BIN` is a 32 KB EPROM holding F-BASIC at `$8000` (`$0000-$7BFF` of the
  file) and a 512-byte boot ROM image at `$FE00`.
- `_8435.BIN` is a 32 KB EPROM whose **top 10240 bytes are byte-identical to
  `subsys_c.rom`** (the Japanese `m153`+`m154`), with character-generator banks
  below. The bank at file offset `$0000` is the Spanish font; the bank at
  `$4000` is byte-identical to the Japanese `m153`.
- `_GPU.BIN` is **byte-identical to the Japanese boot ROM** `TL11_11_M152`,
  despite the name. It is not a GPU and not Spanish.

**Unresolved, and deliberately not guessed at:** `_GPU.BIN` says the Secoinsa
used the stock Japanese boot ROM, while `_8449.BIN` carries a diverged Spanish
one at `$FE00` (same code lineage, 56% agreement after correcting a 6-byte
insertion at offset 11). The set built above uses the Japanese `m152`. The
Spanish variant is extracted to `rtl/roms/secoinsa_bootbas.rom` and is not
wired to anything pending an answer from whoever dumped these.

**Not addressed:** the Secoinsa had a Spanish keyboard. This core's keyboard is
JIS-positional by decision (see `TODO.md`), and a ROM set does not change that.

## The FM-8

Set 2. Built from MAME's `fm8.zip` by `--fm8`; the four files map like this:

| MAME file | size | goes to |
|---|---|---|
| `fbasic10.rom` | 31744 | `m151`, F-BASIC 1.0 |
| `bootbas8.rom` | 512 | `m152` bank 0 (BASIC) |
| `bootdos8.rom` | 512 | `m152` bank 2 (5" DOS) |
| `subsys_8.rom` | 10240 | first 2 KB `m153` (font), the rest `m154` (sub monitor) |

- **The boot ROM layout is the real chip's.** The FM-8's SM11-14 is one
  2 KB part: BASIC / 32 KB bubble / 5" DOS / debug, 512 bytes each
  (`refs/haserin09/difference.html` §7.1). Only banks 0 and 2 were dumped, so
  1 and 3 are `$FF`, and `Boot ROM` = `0` and `2` are the useful settings.
- **Both boot dumps end in `$FF $FF` where the reset vector belongs.** The
  builder writes `$FE00` at offset `$1FE` of every bank, as CSP does on load
  (`mainmem_utils.cpp`, the `p[0x1fe] = 0xfe` loop).
- **The font is the FM-7's less two glyphs** -- 2039 of 2048 bytes agree
  (difference.html §4.1: the FM-7 widened two arcs by a dot).
- **The sub monitor is a different program** (165 of 8192 bytes agree) but it
  touches exactly the FM-7's sub-side registers: `$D400 $D402-$D404
  $D408-$D40A $D40D $D40E`.
- MAME marks `fbasic10.rom` and `subsys_8.rom` `BAD_DUMP`. Both boot and run
  software in CSP and in this core; nothing found so far says they are wrong.
