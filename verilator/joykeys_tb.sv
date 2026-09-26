// Directed checks for rtl/JOYKEYS.v -- the joypad-to-keyboard merger.
//
//   make joykeys-test
//
// A 10-cycle "millisecond" (CLK_HZ = 10_000) keeps every case short; the
// module only ever counts in ms ticks, so nothing here depends on the real
// clock. Each case records the events the module emits as {pressed, code}
// and compares the whole list, so an extra event fails as loudly as a
// missing one. Every rule in JOYKEYS.v's header has a case here.
`timescale 1ns/1ns
module joykeys_tb;

localparam [8:0] KP2 = 9'h072, KP4 = 9'h06b, KP5 = 9'h073, KP6 = 9'h074,
                 KP8 = 9'h075, KP9 = 9'h07d, RET = 9'h05a, SPC = 9'h029;
localparam R = 0, L = 1, D = 2, U = 3, A = 4, B = 5;

reg         clk = 0, rst_n = 0, en = 1, scan = 0;
reg  [11:0] joy = 0;
reg  [10:0] ps2_in = 0;
wire [10:0] ps2_out;

JOYKEYS #(.CLK_HZ(10_000), .STOP_MS(50)) dut(
  .CLK(clk), .RESETn(rst_n), .ENABLE(en), .SCAN_MODE(scan),
  .JOY(joy), .PS2_IN(ps2_in), .PS2_OUT(ps2_out));

always #5 clk = ~clk;

// Event log: every toggle of PS2_OUT[10] is one key event.
reg  [9:0] ev [0:63];
integer    nev = 0;
reg        last_t = 0;
always @(posedge clk) begin
  last_t <= ps2_out[10];
  if (ps2_out[10] != last_t) begin ev[nev] <= ps2_out[9:0]; nev <= nev + 1; end
end

integer fails = 0, checks = 0;

task automatic ms(input integer n); repeat (n * 10) @(posedge clk); endtask
task automatic clear; begin ms(1); nev = 0; end endtask

task automatic check_ev(input string name, input integer n, input [9:0] e0 = 0,
                      input [9:0] e1 = 0, input [9:0] e2 = 0, input [9:0] e3 = 0,
                      input [9:0] e4 = 0, input [9:0] e5 = 0);
  reg [9:0] want [0:5];
  integer i; reg ok;
  begin
    want[0] = e0; want[1] = e1; want[2] = e2; want[3] = e3; want[4] = e4; want[5] = e5;
    ok = (nev == n);
    for (i = 0; i < n && i < 6; i = i + 1) if (ev[i] !== want[i]) ok = 0;
    checks = checks + 1;
    if (ok) $display("PASS  %s", name);
    else begin
      fails = fails + 1;
      $write("FAIL  %s: got %0d event(s):", name, nev);
      for (i = 0; i < nev; i = i + 1) $write(" %s%03x", ev[i][9] ? "+" : "-", ev[i][8:0]);
      $display("");
    end
  end
endtask

function [9:0] P(input [8:0] c); P = {1'b1, c}; endfunction  // press
function [9:0] X(input [8:0] c); X = {1'b0, c}; endfunction  // release

initial begin
  ms(2); rst_n = 1; ms(2);

  // 1. Up, held, released: KP8 down, KP8 up, then after 50 ms the stop.
  clear; joy[U] = 1; ms(5); joy[U] = 0; ms(80);
  check_ev("tap up -> 8, release, then stop key 5", 4, P(KP8), X(KP8), P(KP5), X(KP5));

  // 2. The stop waits the full STOP_MS: nothing at 30 ms.
  clear; joy[L] = 1; ms(5); joy[L] = 0; ms(30);
  check_ev("no stop before 50 ms of neutral", 2, P(KP4), X(KP4));
  ms(40); clear;   // let that stop land, then drop it from the next case

  // 3. Direction change through neutral (an analog stick flick): no stop.
  joy[L] = 1; ms(5); joy[L] = 0; ms(20); joy[R] = 1; ms(5);
  check_ev("left -> neutral 20 ms -> right: no stop in between", 3, P(KP4), X(KP4), P(KP6));
  joy[R] = 0; ms(80); clear;

  // 4. Diagonal, and a direct change: up -> up+right, release old then press new.
  joy[U] = 1; ms(5); joy[R] = 1; ms(5);
  check_ev("up then up+right: 8 released before 9 pressed", 3, P(KP8), X(KP8), P(KP9));
  joy = 0; ms(80); clear;

  // 5. Scan-code mode reports releases itself: no synthetic stop.
  scan = 1; joy[D] = 1; ms(5); joy[D] = 0; ms(80);
  check_ev("scan mode: release only, no stop", 2, P(KP2), X(KP2));
  scan = 0; clear;

  // 6. A real key pressed after the pad was used: the stop is not ours to send.
  joy[U] = 1; ms(5); joy[U] = 0; ms(2);
  ps2_in = {~ps2_in[10], 1'b1, 9'h01c}; ms(80);     // real 'A' press
  check_ev("real key after the pad: no stop", 3, P(KP8), X(KP8), P(9'h01c));
  ps2_in = {~ps2_in[10], 1'b0, 9'h01c}; ms(2); clear;

  // 7. A held button postpones the stop until it is let go.
  joy[A] = 1; ms(3); joy[U] = 1; ms(5); joy[U] = 0; ms(80);
  check_ev("button held: stop waits", 3, P(RET), P(KP8), X(KP8));
  joy[A] = 0; ms(80);
  check_ev("button released: then the stop", 6, P(RET), P(KP8), X(KP8), X(RET), P(KP5), X(KP5));
  clear;

  // 8. Buttons map as keys.
  joy[B] = 1; ms(3); joy[B] = 0; ms(3);
  check_ev("B -> SPACE down/up", 2, P(SPC), X(SPC));
  clear;

  // 9. Option off: the pad produces nothing at all.
  en = 0; joy[U] = 1; joy[A] = 1; ms(5); joy = 0; ms(80);
  check_ev("option off: silent", 0);
  en = 1; clear;

  // 10. Real keys pass through untouched, pad or no pad.
  ps2_in = {~ps2_in[10], 1'b1, 9'h05a}; ms(1);
  ps2_in = {~ps2_in[10], 1'b0, 9'h05a}; ms(1);
  check_ev("real key passes through", 2, P(9'h05a), X(9'h05a));
  clear;

  // 11. Reset mid-hold does not block a real key.
  joy[U] = 1; ms(5); rst_n = 0; ms(1);
  ps2_in = {~ps2_in[10], 1'b1, 9'h029}; ms(2); rst_n = 1; joy = 0; ms(80);
  check_ev("real key during reset still passes", 2, P(KP8), P(9'h029));

  $display("%0d/%0d joykeys checks passed", checks - fails, checks);
  if (fails) $fatal(1, "joykeys: %0d failure(s)", fails);
  $finish;
end

endmodule
