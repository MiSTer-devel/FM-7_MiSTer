// Directed checks for the tape-turbo leg of rtl/CLKCTRL.v's MCPUCLK.
//
//   make clkturbo-test
//
// The main CPU's clock is switched between SCLK1 (8 MHz) and CLKSYS/2 (24 MHz)
// while it runs, so the switch itself is what is checked: off, MCPUCLK must be
// SCLK1 edge for edge; on, a clean 24 MHz; and across any number of switches
// no high phase may be cut short. SCLK1 is high 3 CLKSYS cycles and the fast
// leg 1, so every high phase is 1 or 3 -- a 2 is a truncated SCLK1 pulse.
`timescale 1ns/1ns
module clkturbo_tb;

reg clk = 0;
always #5 clk = ~clk;

wire SCLK1;
clk_en #(CORE_CLK_8) u_sclk1(.ref_clk(clk), .clk(SCLK1));

reg turbo = 0, machine_av = 0, mmr_enabled = 0;
wire MCPUCLK, turbo_on;

CLKCTRL dut(
  .SW2(1'b1), .machine_av(machine_av), .mmr_enabled(mmr_enabled), .CLKSYS(clk),
  .SCLK1(SCLK1), .SCLK2(1'b0), .SCLKNMIn(1'b1), .RFD00n(1'b1), .RFD03n(1'b1),
  .KEYINn(1'b1), .LPINTn(1'b1), .TMMASK(1'b1), .SVIDEOCLK(1'b0), .IOSn(1'b1),
  .BTRDYn(1'b1), .EB(1'b0), .RESETBn(1'b0), .MRDYn(), ._2MS(), .IRQCLRn(1'b1),
  .EXTIRQ(1'b0), .FMIRQn(1'b1), .turbo(turbo), .turbo_on(turbo_on),
  .MCPUCLK(MCPUCLK), .SCPUCLK(), .MDATABUS_out(), .IRQn(), .switch(),
  .CLK2_5(), .CLK1_2(), .CLK0_3());

integer fails = 0, checks = 0;
task automatic check(input string what, input logic ok);
  checks++;
  if (!ok) begin fails++; $display("FAIL %s", what); end
endtask

// Phase lengths of MCPUCLK, in CLKSYS cycles, sampled just after each edge.
integer run = 0, high_bad = 0, low_bad = 0, highs = 0, switches = 0;
reg last = 0, last_on = 0;
always @(posedge clk) begin
  #1;
  if (MCPUCLK == last) run++;
  else begin
    if (last && !(run == 1 || run == 3)) begin
      high_bad++; if (high_bad < 5) $display("high phase of %0d at %0t", run, $time);
    end
    if (!last && !(run >= 1 && run <= 3)) begin
      low_bad++; if (low_bad < 5) $display("low phase of %0d at %0t", run, $time);
    end
    if (last) highs++;
    run = 1; last = MCPUCLK;
  end
  if (turbo_on != last_on) switches++;
  last_on = turbo_on;
end

integer i, mism, toggles, lat;
initial begin
  repeat (20) @(posedge clk);

  // --- off: MCPUCLK is SCLK1 itself ---
  mism = 0;
  for (i = 0; i < 600; i++) begin @(posedge clk); #2; if (MCPUCLK !== SCLK1) mism++; end
  check("turbo off: MCPUCLK == SCLK1 every cycle", mism == 0);

  // --- on: enters within one SCLK1 period, then toggles every cycle ---
  @(posedge clk); turbo <= 1; lat = 0;
  while (!turbo_on && lat < 20) begin @(posedge clk); lat++; end
  check("turbo on within one SCLK1 period", turbo_on && lat <= 6);
  repeat (2) @(posedge clk);
  toggles = 0;
  for (i = 0; i < 100; i++) begin
    @(posedge clk); #2; last_on = MCPUCLK; @(posedge clk); #2;
    if (MCPUCLK != last_on) toggles++;
  end
  check("turbo on: 24 MHz, a toggle every CLKSYS cycle", toggles == 100);

  // --- off again: back on SCLK1 within one period ---
  @(posedge clk); turbo <= 0; lat = 0;
  while (turbo_on && lat < 20) begin @(posedge clk); lat++; end
  check("turbo off within one SCLK1 period", !turbo_on && lat <= 7);
  repeat (8) @(posedge clk);
  mism = 0;
  for (i = 0; i < 600; i++) begin @(posedge clk); #2; if (MCPUCLK !== SCLK1) mism++; end
  check("after turbo: MCPUCLK == SCLK1 again", mism == 0);

  // --- the FM77AV's MMR leg (48/7 MHz) has no 3x: turbo is refused ---
  machine_av <= 1; mmr_enabled <= 1; turbo <= 1;
  repeat (100) @(posedge clk);
  check("no turbo on the 48/7 MHz MMR leg", !turbo_on);
  mmr_enabled <= 0;
  repeat (10) @(posedge clk);
  check("FM77AV with MMR off: turbo", turbo_on);
  machine_av <= 0; turbo <= 0;
  repeat (10) @(posedge clk);

  // --- random switching: no high phase cut short, no low phase lost ---
  switches = 0; high_bad = 0; low_bad = 0;
  for (i = 0; i < 20000; i++) begin
    @(posedge clk);
    if ($urandom_range(0, 15) == 0) turbo <= ~turbo;
  end
  $display("random: %0d switches", switches);
  check("random: many switches exercised", switches > 500);
  check("random: every high phase is 1 or 3 cycles", high_bad == 0);
  check("random: every low phase is 1..3 cycles", low_bad == 0);

  $display("clkturbo: %0d checks, %0d failures", checks, fails);
  if (fails) $fatal(1, "clkturbo_tb FAILED");
  $finish;
end
endmodule
