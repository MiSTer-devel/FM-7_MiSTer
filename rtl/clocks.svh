
localparam CORE_CLK_SYS  = 48;

localparam CORE_CLK_16   = (CORE_CLK_SYS/16)-1;
localparam CORE_CLK_8    = (CORE_CLK_SYS/8)-1;
localparam CORE_CLK_4    = (CORE_CLK_SYS/4)-1;
localparam CORE_CLK_2    = (CORE_CLK_SYS/2)-1;

localparam CORE_CLK_4_9  = 9;   // 48/4.8-1
// FM77AV main CPU with MMR enabled: 2 MHz drops to 1.6 MHz (FM-Techknow p.334).
// 6.4 MHz is not an integer divide of 48; 48/7 = 6.857 MHz gives E = 1.714 MHz.
localparam CORE_CLK_6_8  = 6;
// One T77 duration unit: 9.000 us (77AVEMU NANOSEC_PER_T77_ONE = 9000,
// fm77avtape.h:32), 2*(215+1)/48 MHz. What a tape load depends on is the RATIO
// of main-CPU E cycles to T77 units: F-BASIC decides each bit by sampling $FD02
// a software-loop delay after the rising edge (fbasic300.rom $f43d-$f4c7). Both
// references run the main CPU at ~1.8 MHz -- CSP MAINCLOCK_NORMAL 1798000
// (fm7_common.h:79), 77AVEMU 1800000 (fm77avio.cpp:807) -- 16.2 E cycles per
// unit; CLKCTRL.v's DRAM-refresh stall gives this core the same 1.798 MHz.
// Without the stall (2.0 MHz, 18 cycles per unit) the sample landed ~11% early
// and Crash Ball read ten 0 bits as 1 (Device I/O Error).
// (superseded: 193 = 8.083 us, which ran the tape 11% fast to match a
// stall-less 2.0 MHz CPU; 218 = 9.125 us; and an 8.458 us derived from the
// manual's 1600 baud average -- the baud rate falls out of the image's bit mix.)
localparam DIV_T77       = 215;
localparam PCM_CLK       = 59;  // 48/0.8-1
