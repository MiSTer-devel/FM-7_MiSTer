// Joypad-to-keyboard: the MiSTer pad as FM-7 keys, merged into ps2_key.
//
// Why it exists: the FM-7 encoder sends a code on press and NOTHING on release
// (KEYBOARD.v, $FD01 holds the last code), so games steer with the numeric
// keypad as an eight-way pad and use keypad 5 as the stop key. Only a few dozen
// titles read the PSG joystick ports at all (docs/IO_MAP.md), so for the rest a
// gamepad does nothing. This turns the pad into the keys those games expect:
//
//   d-pad, 8 ways   keypad 1-4, 6-9        A  RETURN     B  SPACE
//   d-pad released  keypad 5 (the stop)    X  keypad 5   Y  CTRL
//   Start ESC  Select F1  L N  R Y
//
// Events are synthesised as ps2_key toggles, the same word hps_io delivers, so
// KEYBOARD.v cannot tell a pad from a keyboard and every table, repeat and
// routing rule applies unchanged. Real keys pass straight through and always
// win a collision; pad events go out at most one per millisecond, which keeps
// a direction change (release old, press new) in order.
//
// The stop key is the whole point, and three rules keep it from misfiring:
//   * STOP_MS of neutral first. An analog stick mapped to the d-pad crosses
//     neutral for a frame or two when flicked left to right; a stop there
//     would halt the character on every turn. 50 ms is below what a hand
//     notices and above that crossing.
//   * Never after a real key pressed more recently than the pad was used, and
//     never while a pad button is held -- a held RETURN auto-repeats, and a 5
//     between repeats would interleave codes in $FD01 for nothing.
//   * Not in the FM77AV's scan-code mode: that encoder reports releases itself
//     (KEYBOARD.v), so a title using it sees a genuine break code instead.
// One press of 5 is enough: $FD01 holds it until the next key.
module JOYKEYS #(
  parameter CLK_HZ  = 48_000_000,
  parameter STOP_MS = 50
)(
  input             CLK,
  input             RESETn,
  input             ENABLE,       // OSD "Joypad keys"
  input             SCAN_MODE,    // FM77AV encoder reporting releases itself
  input      [11:0] JOY,          // [0]R [1]L [2]D [3]U [4]A [5]B [6]X [7]Y [8]L [9]R [10]Select [11]Start
  input      [10:0] PS2_IN,
  output reg [10:0] PS2_OUT
);

localparam [8:0] KP1 = 9'h069, KP2 = 9'h072, KP3 = 9'h07a, KP4 = 9'h06b,
                 KP5 = 9'h073, KP6 = 9'h074, KP7 = 9'h06c, KP8 = 9'h075,
                 KP9 = 9'h07d;

// Buttons in JOY[11:4] order.
function [8:0] btn_code;
  input [2:0] i;
  case (i)
    3'd0: btn_code = 9'h05a;   // A      RETURN
    3'd1: btn_code = 9'h029;   // B      SPACE
    3'd2: btn_code = KP5;      // X      keypad 5, the stop on purpose
    3'd3: btn_code = 9'h014;   // Y      CTRL (left)
    3'd4: btn_code = 9'h031;   // L      N
    3'd5: btn_code = 9'h035;   // R      Y
    3'd6: btn_code = 9'h005;   // Select F1
    3'd7: btn_code = 9'h076;   // Start  ESC
  endcase
endfunction

// Opposite directions together cancel on that axis.
wire right = JOY[0] & ~JOY[1];
wire left  = JOY[1] & ~JOY[0];
wire down  = JOY[2] & ~JOY[3];
wire up    = JOY[3] & ~JOY[2];

reg [8:0] want_dir;
always @(*) begin
  case ({up, down, left, right})
    4'b1000: want_dir = KP8;
    4'b0100: want_dir = KP2;
    4'b0010: want_dir = KP4;
    4'b0001: want_dir = KP6;
    4'b1010: want_dir = KP7;
    4'b1001: want_dir = KP9;
    4'b0110: want_dir = KP1;
    4'b0101: want_dir = KP3;
    default: want_dir = 9'd0;
  endcase
end

wire [8:0] want_d   = ENABLE ? want_dir  : 9'd0;
wire [7:0] want_btn = ENABLE ? JOY[11:4] : 8'd0;

// First button whose state differs from what has been sent.
reg [7:0] btn_sent;
wire [7:0] btn_diff = want_btn ^ btn_sent;
reg [2:0] btn_i;
integer k;
always @(*) begin
  btn_i = 3'd0;
  for (k = 7; k >= 0; k = k - 1)
    if (btn_diff[k]) btn_i = k[2:0];
end

localparam MS_DIV = CLK_HZ / 1000;
reg [$clog2(MS_DIV)-1:0] ms_cnt;
wire ms_tick = (ms_cnt == MS_DIV - 1);

reg  [8:0] dir_sent;          // direction key currently held down, 0 = none
reg        stop_arm;          // a direction was released and no stop sent yet
reg  [7:0] stop_cnt;          // ms of neutral so far
reg        stop_up;           // keypad 5 pressed by the stop, release pending
reg        kbd_newer;         // a real key was pressed after the pad was last used
reg        pend;              // a pad event waiting for a cycle with no real key
reg  [9:0] pend_ev;           // {pressed, code}

reg old_in = 1'b0;
initial PS2_OUT = 11'd0;
wire real_ev = (old_in != PS2_IN[10]);

always @(posedge CLK) begin
  old_in <= PS2_IN[10];
  ms_cnt <= ms_tick ? 0 : ms_cnt + 1'd1;

  if (real_ev) begin
    // Real keys first, always, and untouched.
    PS2_OUT <= { ~PS2_OUT[10], PS2_IN[9:0] };
    if (PS2_IN[9]) kbd_newer <= 1'b1;
  end
  else if (pend) begin
    PS2_OUT <= { ~PS2_OUT[10], pend_ev };
    pend    <= 1'b0;
  end
  else if (ms_tick) begin
    // At most one pad event per millisecond, most urgent first.
    if (stop_up) begin
      pend <= 1'b1; pend_ev <= { 1'b0, KP5 }; stop_up <= 1'b0;
    end
    else if (dir_sent != 9'd0 && dir_sent != want_d) begin
      pend <= 1'b1; pend_ev <= { 1'b0, dir_sent };
      dir_sent <= 9'd0;
      stop_arm <= ENABLE; stop_cnt <= 8'd0;
    end
    else if (dir_sent == 9'd0 && want_d != 9'd0) begin
      pend <= 1'b1; pend_ev <= { 1'b1, want_d };
      dir_sent <= want_d;
      stop_arm <= 1'b0; kbd_newer <= 1'b0;
    end
    else if (btn_diff != 8'd0) begin
      pend <= 1'b1; pend_ev <= { want_btn[btn_i], btn_code(btn_i) };
      btn_sent[btn_i] <= want_btn[btn_i];
      if (want_btn[btn_i]) kbd_newer <= 1'b0;
    end
    else if (stop_arm) begin
      if (~ENABLE || SCAN_MODE || kbd_newer)
        stop_arm <= 1'b0;                        // nothing to stop, or not ours to
      else if (btn_sent != 8'd0)
        ;                                        // wait for the buttons
      else if (stop_cnt < STOP_MS)
        stop_cnt <= stop_cnt + 1'd1;
      else begin
        pend <= 1'b1; pend_ev <= { 1'b1, KP5 };
        stop_up <= 1'b1; stop_arm <= 1'b0;
      end
    end
  end

  // Reset clears the pad's state and nothing else: a real key still passes
  // through above while the machine is held in reset. Last, so it wins.
  if (~RESETn) begin
    dir_sent <= 9'd0; btn_sent <= 8'd0;
    stop_arm <= 1'b0; stop_cnt <= 8'd0; stop_up <= 1'b0;
    kbd_newer <= 1'b0; pend <= 1'b0;
  end
end

endmodule
