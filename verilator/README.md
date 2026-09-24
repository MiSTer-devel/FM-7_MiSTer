# FM-7 Verilator simulation

Runs the core on the host, headless or windowed, so you can boot it, type at it,
screenshot the result and **disassemble what either 6809 is actually executing**
— without a DE10-Nano and without a Quartus build.

Modelled on the RX-78 `vsim/` setup, sharing its `sim/` framework (imgui + SDL2 +
`sim_bus`/`sim_video`/`sim_input`).

> There is an older, untracked `verilog/` directory in this repo from the same
> lineage. It is superseded by this one: its `sim.v` leaves `sdram_data` and
> `sdram_ready` undriven (so the tape path could never work), it has no
> disassembler, no debug taps, no reset prologue, and no regression script.
> Nothing here depends on it.

## Build

```sh
cd verilator
make            # -> ./obj_dir/Vemu
make run        # build + launch the windowed sim
make test       # build + headless regression sweep
make distest    # disassembler self-check (standalone, ~1s)
```

Needs Verilator and SDL2 (`brew install verilator sdl2`). Verilator 4.204 and
5.x both build it -- the 4.x differences (no `WIDTHEXPAND` lint code, no
`Vemu___024root.h`) are absorbed by the `VL_ROOT()` shim in `sim_main.cpp`.
Both CPUs are `mc6809i` (Verilog), so there is no VHDL and no ghdl step.

`roms` and `audio` here are symlinks to `../rtl/roms` and `../audio`, because
`rtl/rom.v` and `rtl/pcm.v` do literal `$readmemh("./roms/…")` /
`$readmemb("./audio/…")` relative to the working directory. **Run the binary from
this directory.**

Speed is **about 2.2 simulated frames per second**, measured 2026-09-21 on an
Apple-silicon Mac with Verilator 5.044: 120 frames in 54.1 s, i.e. 0.45 s a
frame and about 27x slower than the machine runs. Budget from that: 1000 frames
~7.5 min, 2000 ~15 min, 10,000 ~75 min. That figure was taken with a load
average of 36, so an idle box does better -- **time your own before planning an
afternoon around it**:

```sh
time ./obj_dir/Vemu --headless --machine fm77av --stop-at-frame 120
```

(Superseded claims, both measured and both once true: *"around 6 frames per
second"*, and *"about 1 frame per second"* -- the latter on Verilator 4.204,
which 5.044 roughly doubles. The number moves with the toolchain, which is why
the command to re-measure it is above.)

The cost is dominated by clocking the whole design at 48 MHz `clk_sys`; faking
that would change the phase relationship between the two CPUs and the video
chain, which is exactly what the core depends on.

**Do not reach for `--threads`. It is 9x SLOWER and it changes the answer.**
Measured on the same 400-frame FM77AV disk run, one build with and one without:

| | default | `--threads 8` |
|---|---|---|
| wall | **7 m 13 s** | **68 m 02 s** |
| CPU time | 7 m 13 s | 9 h 04 m |
| main 6809 | 7740 instr/frame | 9410 |
| sub 6809 | **679** instr/frame | **8752** |
| I/O cycles (`$fdxx`) | 693,120 | 23,239 |

The wall-clock loss is the usual story -- one 48 MHz clock drives everything, so
the mtasks come out tiny and the per-cycle barrier costs more than the work it
spreads. **The divergence is the part that matters:** the sub CPU retires
thirteen times as many instructions and the I/O count falls by 30x, so the
threaded model is simulating a different machine, not the same one faster. This
design settles iteratively -- note `--converge-limit 6000` in the Makefile --
and threaded scheduling does not reproduce that ordering. Every trace, profile
and screenshot from a threaded build would be quietly wrong.

## Directed tests

Small testbenches that need nothing but Verilator -- no ROMs, no disk images, no
built `Vemu`. Each builds and runs itself:

```sh
make keyboard-test     # the key tables, $FD01 across release and reset,
                       # auto-repeat, and the FM77AV scan-code mode
make avkeyboard-test   # the FM77AV encoder's command/status pair at $D431/$D432
make avmem-test        # AV memory paths        make crtram-test    # CRT RAM
make smem-test         # AV character generator make pal-test       # analog palette
make avpixel-test      # 12-plane pixel combine make avhdraw-test   # drawing ALU
make mb60h010-test     # AV raster address      make sound-test     # PSG / YM2203
make distest           # the 6809 disassembler, no Verilator at all
```

A testbench reports every failing check and then exits non-zero, so one run
shows everything a change broke.

## Headless use

```sh
# boot F-BASIC and grab a frame
./obj_dir/Vemu --headless --screenshot 300 --stop-at-frame 320

# type at it
./obj_dir/Vemu --headless --key 300:print 1+1 --key 380:@RETURN \
    --screenshot 450 --stop-at-frame 470

# mount a tape and ask F-BASIC to load it
./obj_dir/Vemu --headless --tape /path/to/game.t77 \
    --key 400:load\"\" --key 500:@RETURN --stop-at-frame 3000

# boot an FM77AV disk in both drives and sample the intro
./obj_dir/Vemu --headless --machine fm77av --disk "Disk A.d77" --disk1 "Disk B.d77" \
    --screenshot 400,900,1500 --stop-at-frame 2000
```

`--help` lists everything. The options that matter:

| Option | Notes |
|---|---|
| `--tape <file.t77>` | Loaded through the real `ioctl` path at index 1, exactly as `hps_io` does for `F1,t77`, into the behavioural SDRAM and played by `rtl/t77_decode.v`. |
| `--disk <file>` / `--disk1 <file>` | Mount a `.d77`/`.d88` in drive 0 / drive 1, through the same `sd_rd`/`sd_ack` block-device interface `hps_io` drives on hardware (`verilator/sim/sim_blkdevice.cpp`). Writes are discarded unless `--disk-writable`. |
| `--disk-index <0-7>` / `--disk1-index <0-7>` | Which sub-disk of a multi-disk container that drive presents -- the `Disk 1 image` / `Disk 2 image` OSD rows. |
| `--romset <file>` / `--romset-sel <0\|1>` | Load a `boot1.rom` system-ROM set and pick set 0 (Japanese) or 1 (Spanish), matching the `System ROM` OSD row. |
| `--tape-audio` / `--rewind-at-frame <n>` | The `Tape Audio` and `Tape Rewind` OSD bits. |
| `--bootrom <0-3>` | The `BootROM` OSD bits: 0 = F-BASIC, 1-3 = the DOS boot ROMs. |
| `--machine <fm7\|fm77av>` | Machine-family selector matching the OSD. (Superseded claim: *"`fm77av` is a bring-up gate and currently holds the core in reset until the AV backend is implemented"*. It selects the real AV family now -- memory map, video, sub-I/O and the YM2203 -- and AV disks boot under it. An AV title run without it reports a uniform "nothing boots", which reads as a core failure rather than as the wrong switch.) |
| `--key <frame>:<text>` | Types text, or `@NAME` for `SPACE RETURN TAB BS ESC CAPS UP DOWN LEFT RIGHT HOME INS DEL CTRL SHIFT GRAPH KANA BREAK F1`..`F10`, and the keypad `KP0`..`KP9 KPDOT KPPLUS KPMINUS KPSTAR KPSLASH KPENTER`. `@KP8` is not `@UP`: the same scancode, without the E0 prefix. |
| `--key-hold <frames>` | Frames to hold each key, default 6. |
| `--key-typematic <d>:<i>` | While a key is held, resend its make code after *d* frames and then every *i*, as a PC keyboard's typematic does. The core must ignore these -- `KEYBOARD.v` repeats at the FM-7's own 0.7 s / 0.07 s -- so a 120-frame hold still delivers 20 keystrokes with or without it. On MiSTer this tests a guard, not a live path: Main_MiSTer does not forward key repeats to a core that leaves `hps_io`'s `PS2WE` unset, as this one does (`user_io.cpp:4070`). |
| `--screenshot <n,...>` / `--screenshot-name <path>` | PNG per listed frame / exact path, for scripting. |
| `--stop-at-frame <n>` | Required for headless runs; otherwise it stops at 100000 frames. |
| `--trace-cpu [file]` | Disassemble every main-CPU instruction as it retires. See below. |
| `--trace-io [file]` | Every `$fdxx` read/write with the port, the data and the PC. |
| `--trace-mem <lo>-<hi>` | Every main-CPU bus cycle in a hex address range, with the memory-map chip selects. |
| `--dump-shadow <file>` | The 64K of bytes the CPU has actually seen on its bus. |
| `--joystick <frame>:<buttons>[:<hold>]` | Press stick 1 buttons (`up down left right a b fire none`, `+`-joined). **`--joystick-hold` applies only to options after it** — use the per-action `<hold>` instead. |
| `--wav <file>` | Capture `AUDIO_L`/`AUDIO_R` to a 16-bit stereo RIFF/WAVE at 44100 Hz. Works headless — `audio.Clock()` is otherwise skipped without a window, which is why the sound path went unverified for so long. |
| `--trace-av-video [file]` | FM77AV video writes: main aperture, sub VRAM, drawing ALU, MMR sub-I/O, `$D4xx`. Off by default; it is per-bus-cycle noisy. |
| `--av-dump-frame <n>` + `FM7_VRAM_DUMP=<file>` | Write the 12 FM77AV VRAM planes at frame *n*, in the reference emulator's plane layout, for byte-for-byte VRAM comparison. |

(Superseded claim: *"there is no joystick option because the core has no
joystick input — `core.v` takes `ps2_key` and nothing else"*. Both sticks are
wired now, from `core.v` through `SOUND.v` onto the PSG's I/O ports, and
`--joystick` / `--joystick2` drive them.)

Everything schedulable is in **frames**, not cycles, because frames stay
meaningful across clock changes; a cycle-based schedule has to be rewritten
every time a divider in `rtl/clocks.svh` moves.

## Record, replay and capture

For a fault a scripted `--key` cannot reach. Albatross's mini-map glitch and its
crash on the putt are several menus and most of a hole of golf in; at 2.2 frames
per second nobody is going to find that keystroke list by guessing. So play it
once in the GUI, record what you pressed, and replay it as often as the question
needs. Ported from the ColecoAdam harness (`f136310`), adapted for a machine
whose primary input is a keyboard rather than a joystick.

```sh
./obj_dir/Vemu --machine fm77av --disk game.d77 --record alba.txt   # play it
./obj_dir/Vemu --headless --machine fm77av --disk game.d77 \
    --replay alba.txt --stop-at-frame 4000                          # and again
```

The file is one line per input change, meant to be read and hand-edited:

```
# fm7 recording: <frame> K <ps2> <down> <ext> | <frame> J <player> <bits>
1240 K 2d 1 0
1243 K 2d 0 0
1310 J 0 08
```

`ps2` is the set-2 code the core receives, `down` 1 for make and 0 for break,
`ext` the E0 flag; joystick bits are MiSTer order, `[0]`=right `[1]`=left
`[2]`=down `[3]`=up `[4]`=A `[5]`=B. **Trim it.** A recording cut to the fifty
frames around the glitch is a fifty-frame experiment instead of a
four-thousand-frame one.

**A replay is faithful, but it is not a recording of a session.** The core has
no randomness, so the same input on the same frames gives the same run -- a
scripted `--key` run and a replay of its own recording produce byte-identical
run summaries, instruction counts and I/O cycles included, which is how this was
checked. The imprecision is that a key pressed part way through a frame replays
from that frame's start, so over thousands of frames a long session can diverge.
Use it to get NEAR a place, then trim.

Replayed keys go through the same queue `--key` uses and inherit its pacing, so
two keys recorded in one frame do not collapse into a single strobe.

### Capturing a glitch

In the GUI, `[` starts capturing every frame, `]` stops, `\` grabs one.
**Not function keys** -- a Mac puts those behind `fn`, which is useless with a
hand on the game. Each capture writes, into `--capture-dir` (default
`captures/`):

| file | what |
|---|---|
| `cap_NNNNN.png` | the picture |
| `cap_NNNNN.vram` | all 96 KB of CRTRAM, the same layout the 77AVEMU comparison dumps |
| `cap_NNNNN.pal` | the palette, as `index r g b` lines |

The second and third are the point. A screenshot of a glitch is only a picture
of a glitch; with the VRAM beside it you can re-render what the core was *told*
to draw and say whether the fault is the display path or the game putting the
wrong bytes there. `--capture-frames A-B` does the same headlessly, so a
recorded session can be re-captured later with different probes compiled in.

Those three keys are claimed by the harness (`SimInput::suppressScancodes`) and
never reach the machine -- otherwise grabbing a frame would also type a bracket
into whatever is running.

## Disassembly and tracing

This is the part worth reading. The FM-7 has two 6809s that talk to each other
through shared RAM, so "the screen is black" has a large number of possible
causes and a screenshot distinguishes none of them.

```sh
# what is the main CPU doing, for one frame
./obj_dir/Vemu --headless --stop-at-frame 1 --trace-cpu boot.log --trace-until 0

# both CPUs, only around the point of interest
./obj_dir/Vemu --headless --stop-at-frame 400 --trace-cpu t.log --trace-sub-cpu t.log \
    --trace-from 380 --trace-until 385
```

```
      0 main  $fe0f  10 ce fc 7f     LDS   #$fc7f  a=fd b=00 x=0000 y=0000 u=0000 s=fc7f dp=fd cc=eFhINzvc
      0 main  $fe13  d6 04           LDB   <$04    a=fd b=ff x=0000 y=0000 u=0000 s=fc7f dp=fd cc=eFhINzvc
```

Registers are the state **after** that instruction retired.

Two things make this work without touching `rtl/`:

- **Instruction boundaries come from the state machine, not from `LIC`.**
  `mc6809i.v` asserts `LIC` on the last cycle of an instruction, at which point
  `pc` has advanced past the operands but not yet through a taken branch — so a
  `LIC`-sampled `pc` is neither the current nor the next instruction's address,
  and the disassembly walks off by one byte at a time. `sim.v` taps
  `CpuState == CPUSTATE_FETCH_I1` instead; `assign ADDR = addr_nxt` with
  `addr_nxt = pc` in that state puts the instruction's own address on the bus.

- **The operand bytes come from a bus shadow.** Every byte either CPU puts on
  its data bus is recorded, so the disassembler has memory to read with no extra
  RTL and no `--public-flat-rw`. An address the CPU has never touched prints as
  `??` rather than as a plausible-looking `$00`.

  The shadow is sampled from the values captured *one `clk_sys` cycle before* E
  falls. A bus cycle ends on E's falling edge, which is also the edge
  `mc6809i.v` advances its state on (`always @(negedge E)`), while the address
  bus is combinational on the *new* state. Sample after that and you pair each
  address with the next cycle's data — which still disassembles, just into
  convincing nonsense. `--dump-shadow` exists so this stays checkable:

  ```sh
  ./obj_dir/Vemu --headless --stop-at-frame 1 --dump-shadow shadow.bin
  # shadow.bin is 64K; shadow.bin.known flags which addresses were really seen.
  # Over the addresses it has seen, shadow.bin[$fe00..$ffff] == rtl/roms/boot_bas.rom.
  ```

Every headless run also ends with the **last 16 instructions of each CPU**
(`--trace-tail n`, 0 disables), which is almost always enough on its own.

`make distest` runs `dis6809_test.cpp` against every addressing mode, both
prefix pages, the register-list and register-pair postbytes, and an undefined
opcode. A disassembler that is subtly wrong is worse than none, because it
produces confident output you will act on.

## Run stats

```
--- run stats ---------------------------------------------
frames            : 201  (3.37 s of machine time)
vblank edges      : 201
main 6809         : 1836622 instructions  (9137 per frame)
     pc range     : $00de .. $ffdf   pc now $f89d
     fetched from : RAM 2  ROM 1836620  I/O 0
     interrupts   : IRQ 2  FIRQ 1  NMI 0   (lines now: IRQ )
sub 6809          : 798341 instructions  (3972 per frame)
     pc range     : $d097 .. $ff69   pc now $e141
     interrupts   : IRQ 0  FIRQ 0  NMI 169
     halted        : 54.6% of cycles
I/O cycles ($fdxx): 770232
keyboard          : 0 strobes, codes seen $00
video             : palette 0 1 2 3 4 5 6 7   $fd37 = $00   scroll $0000   display on
```

How to read it:

- **`fetched from: … I/O n`** is the loudest signal in the whole harness. The
  main CPU's `$fd00-$fdff` window returns `$ff` for anything undecoded, and `$ff`
  is a legal opcode, so a CPU that jumps into it never traps — it just runs
  through all 256 ports and out the other side. Any non-zero count here is a
  runaway, and the run is flagged `RUNAWAY`.
- **`halted: 54.6%`** is *normal* for the sub CPU, not a fault. `MB60H010`
  asserts `SVDHALT` to stall it during active video. A figure near 100% means it
  never got the bus at all.
- **`keyboard: n strobes`** counts `KSTROBEn` falling edges — keystrokes that
  reached the machine. Zero after a `--key` means the injection is broken; a
  non-zero count with nothing on screen means the machine isn't reading it.
- **`palette`** should be `0 1 2 3 4 5 6 7` right after reset — `PAL.v` fills it
  with the identity while `RESETBn` is low.

## Regression sweep

**`run_tests.sh` and its `shots-ref/` baseline are not part of this
repository** -- the sweep boots real disk and tape images and compares against
screenshots of them, neither of which ships here. The directed tests above are
what this repository can run on its own.

```sh
./run_tests.sh              # all tests
./run_tests.sh basic        # substring filter
FRAMES=1200 ./run_tests.sh  # run longer
TAPEDIR=../tapes ./run_tests.sh
```

Boots each of the four BootROM selections, does two keyboard round trips, and
adds one load test per `.t77` found in `$TAPEDIR` (default `../tapes`, absent by
default). Writes one PNG per test to `shots/` and prints the liveness table. To
set a baseline before changing the core:

```sh
./run_tests.sh && cp -r shots shots-ref
# ...make a change, rebuild, re-run...
for f in shots/*.png; do compare -metric AE "$f" "shots-ref/$(basename $f)" null: 2>&1; echo " $f"; done
```

## Deliberate differences from FM-7_MiSTer.sv

All of them are commented at the point they occur in `sim.v`:

- `clk_sys` is driven by `sim_main` instead of the PLL. The PLL's `outclk_0` is
  48.000 MHz, so this is exact, not an approximation.
- `rtl/sdram.sv` (the real controller, with `SDRAM_*` pins) is replaced by the
  behavioural model in `verilator/rtl/sdram.sv`. Same client interface, same
  edge-detected requests and read latency.
- The tape download writes bytes (`wtbt=00`, 8-bit `ioctl_dout`); the FPGA build
  uses `hps_io #(.WIDE(1))` and 16-bit writes. The bytes land at the same
  addresses either way — `SimBus` only speaks 8-bit.
- `VGA_R/G/B` replicate the core's single colour bit across all 8 bits.
  `FM-7_MiSTer.sv` assigns only `VGA_x[7]`, which would make every screenshot
  half-brightness.
- `VGA_VB` clears 384 pixel clocks early, inside the last blanked line.
  `SimVideo` starts a new line when HBLANK falls and a new frame when VBLANK
  falls, and resets the line counter *after* the line increment — and in this
  core `MB60H010` wraps `xx` and `yy` on the same clock, so the frame reset would
  eat the line increment and shift the picture up by one line. HBLANK is high for
  that whole window, so no visible pixel is affected.

### The reset prologue

`sim_main` runs 64 cycles with reset **low** before asserting it. This is not
cosmetic. `ROMS.v` latches the boot ROM select with

```verilog
wire ck = ~RESETBn;
always @(posedge pre, posedge clr, posedge ck)
  ...
  else ff_q <= m120_q;
```

— a flip-flop *clocked by reset being asserted*, not by reset being released.
Start the sim with reset already high and `~RESETBn` never has a rising edge, so
`ff_q` keeps its power-on `0`, `RAM1HB2n` stays high, the F-BASIC ROM is never
chip-selected, and every read of `$8000-$fbff` returns `$00`. The boot ROM then
does `LDX $fbfe` (getting `$0000`) and `JMP ,X`, and the machine executes zeroed
RAM forever.

This is worth knowing beyond the sim: the core's cold-boot behaviour depends on
that edge existing, which makes it sensitive to how `RESET` is sequenced.

## Edits made to `rtl/`

Building this harness needed exactly one change to the RTL: the per-pixel-clock
`$display` in `MB60H010.v` is now behind `` `ifdef DEBUG_MB60H010 ``
(`make DEBUG_VIDEO=1` restores it). It is 16 million lines per simulated second,
so it cannot be left unconditional.

Everything the harness *observes* — every register, both program counters, the
palette, the keyboard latch, the memory-map chip selects — is read out of the
core with hierarchical references in `sim.v`. Nothing in `sim.v` drives the
core, and there is no `--public-flat-rw`.

Separately, *using* the harness turned up four real core bugs, which are now
fixed in `rtl/`: the `$fdxx` read strobe timing
(`core.v`), three modules latching the read bus on writes (`core.v`), the
character-cell shift-register load phase (`MB60H010.v`), and the boot ROM
select (`ROMS.v`).

Note that `rtl/MRAM.v`'s `` `ifdef VERILATOR `` branch (generic `ram` instead of
the Quartus `altsyncram` wrapper) and the trailing-comma fix in `ROMS.v` were
already in the working tree; the sim needs both.

## One harness trap worth knowing

`ce_pix` is `SFTCLK`, which `clk_en` drives as a real 16 MHz clock — high for two
of every three `clk_sys` cycles — **not** a one-cycle enable. Passing it straight
through as `CE_PIXEL` makes `sim_main` sample every pixel twice and doubles the
picture horizontally.

(`run_tests.sh` and `shots-ref/` are the local-only sweep described above; they
are not in this repository.)
