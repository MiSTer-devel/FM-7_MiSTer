# The FM-8 on this core

The FM-8 (1981) is the FM-7's predecessor: the same two-6809 board design, the
same video and sub-system protocol, with less hardware and a slower main CPU.
This core runs it as the FM-7 board with the FM-8 ROM set (`docs/ROMSETS.md`,
set 2) and with the FM-7-only hardware taken away. `Machine` = FM-8 in the OSD,
`--machine fm8` in the sim.

Primary references: CSP `src/vm/fm7/fm8_mainio.cpp` (the FM-8 is a subclass of
the FM-7's main I/O that removes things) and haserin's per-model difference
table, `refs/haserin09/difference.html` (番外編7). MAME's `fm8_mem`
(`refs/mame/src/mame/fujitsu/fm7.cpp:1296`) differs from `fm7_mem` only in
leaving `$fd0d/$fd0e` unmapped.

## What is different from the FM-7

| | FM-8 | where in this core |
|---|---|---|
| main CPU | 1.2288 MHz (CSP `MAINCLOCK_SLOW` 1.095 MHz) | `CLKCTRL` `SW2 = ~machine_fm8` |
| sub CPU | 1 MHz (CSP `SUBCLOCK_SLOW` 0.999 MHz; `display.cpp`: `clock_fast` false only under `_FM8`) | same switch |
| keyboard | **wired to the sub CPU only** (MB8841 -> sub); the main sees BREAK and nothing else (difference.html §1) | main `$fd00` b7 reads 1, `$fd01` reads `$ff` |
| main IRQ | RS-232 only (`FM8_MAINIO::do_irq`) -- no timer, keyboard, printer | `MCPU .IRQn` forced high |
| `$fd03` | reads `$ff` | `core.v` read mux |
| `$fd04` | bit 2 reads 0 (`get_fd04`: `$78` on the FM-8, `$7c` on the FM-7) | `core.v` read mux |
| PSG `$fd0d/$fd0e` | none on a stock FM-8 (CSP `SOUND_TYPE_DEFAULT 0`) | writes gated, `$fd0e` reads `$ff` |
| palette `$fd38-$fd3f` | none; colours fixed at the identity map, reads `$ff` | `PAL` write gated |
| multipage `$fd37` | none | `FLAGS` write gated |
| bubble cassette `$fd10-$fd17` | optional unit, CSP always has it | not modelled (reads `$ff`) |
| tape turbo | no 3x (the FM-8 leg is `CLK4_9`; only the 8 MHz leg has a 3x) | `CLKCTRL turbo_ok` needs `switch` |

Unchanged: VRAM and the sub-side registers (the FM-8 sub monitor touches
exactly the FM-7's set), the shared RAM handshake, `$fd05`, the FDC, the kanji
ROM window, the cassette port. F-BASIC 1.0 itself touches only `$fd00` (write),
`$fd04`, `$fd05`, `$fd06` (RS-232 probe), `$fd10` (bubble probe) and `$fd22`.

## Where the references disagree

**`$fd0f`, ROM/RAM mode.** haserin (difference.html §7.1) says the FM-8 takes
ROM-vs-RAM mode **directly from the DIP switch, in real time, with no software
switch** -- the FM-7 added the `$fd0f` read/write switching. CSP implements
`$fd0f` on the FM-8 as on the FM-7 unless its `FM7_DIPSW_FM8_PROTECT_FD0F`
switch is set, and that switch is off by default. **This core follows CSP's
default** (the FM-7 path, unchanged); nothing tested so far writes `$fd0f`.
Unverified on hardware.

**`$fd05` bit 0, "external device present", 0 = present.** 77AVEMU returns 0
always (`fm77av.cpp:667`, `ExternalDevicePresent` "Has FDD"). CSP never drives
it (`extdet_neg` is only ever set false), so it reads 1 even with its floppy
unit connected. This core ties it 0 (`core.v` `EXTDETn`), matching 77AVEMU and
the fact that it always has an FDC. Consequence: the boot ROM (FM-7 and FM-8
alike) tries the floppy first, and with no disk waits for that to fail -- **this
core's FM-8 reaches `Ready` at about frame 280, CSP's at about 150.** Align on
the screen, not the frame number, when comparing the two; a scripted key before
`Ready` is lost on both.

**Bytes free.** CSP's FM-8 prints **30280 Bytes Free**, this core **30358**.
F-BASIC 1.0 writes `$55` to `$fd10` and reads it back (`$8a24-$8a33`); CSP
always has a bubble controller there, so BASIC reserves 2 x `$27` = 78 bytes for
it. This core has none. Not a bug, and not a reason to model the bubble unit.

**Sub CPU clock.** MAME's `fm8` runs the sub from `16.128_MHz_XTAL / 2`, i.e.
2 MHz; the FM-7 manual's FM-8-compatibility mode and CSP both say 1 MHz. This
core uses 1 MHz.

## Test material

MAME's `fm8_cass` software list, 25 titles, all `.t77`, which this core's tape
loader reads. A copy is in the sibling fork,
`../FM-7_MiSTer_alanswx/software/mame0289/fm8_cass/`. Machine-code tapes (Tank
Game: `Found: 99M`) want `LOADM"",,R`; BASIC ones (`Found: GA`, `STR`,
`GB+G1`) want `RUN""`. At the FM-8's 1.2 MHz and with no 3x, Tank Game takes
about 4100 frames to load and Elevator Game about 4500 -- 35-40 minutes of sim.
