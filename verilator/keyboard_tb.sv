// Directed check for KEYBOARD.v: the table entries that were checked against the
// Fujitsu manuals and XM7, what $FD01 reads across a key release and a reset,
// and the auto-repeat timer.
//
//   make keyboard-test
//
// Every check reports, and the run fails at the end if any did, so a regression
// shows everything it broke at once.
module keyboard_tb;
  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg        resetn = 1'b0;
  reg [10:0] ps2_key = 11'd0;
  reg        rfd00n = 1'b1, rfd01n = 1'b1;
  reg        eb = 1'b0;               // E phase: a $FD01 read ending in it acknowledges
  reg        rpt_mode_stb = 1'b0, rpt_mode_on = 1'b1, rpt_time_stb = 1'b0;
  reg  [7:0] rpt_delay = 8'd0, rpt_interval = 8'd0;
  reg  [1:0] key_coding = 2'd0;   // FM77AV encoder $00: 0 FM-7, 2 scan codes
  wire [7:0] mkdata, skdata;
  wire       kstroben, breakn, lpmaskn, tmmask, keyinn, caps, kana;
  reg        led_stb = 1'b0;
  reg  [1:0] led_val = 2'd0;

  KEYBOARD dut(
    .CLKSYS(clk), .RESETBn(resetn), .ps2_key(ps2_key), .MDATA_in(8'h00),
    .SKDATA(skdata), .MKDATA(mkdata), .KDATAn(1'b1), .KACKNGn(1'b1),
    .RFD00n(rfd00n), .RFD01n(rfd01n), .EB(eb), .SEB(1'b0), .SCLK2(1'b0),
    .WFD02n(1'b1), .KSTROBEn(kstroben), .BREAKn(breakn), .fm8_switch(1'b1),
    .LPMASKn(lpmaskn), .TMMASK(tmmask), .KEYINn(keyinn),
    .RPT_MODE_STB(rpt_mode_stb), .RPT_MODE_ON(rpt_mode_on),
    .RPT_TIME_STB(rpt_time_stb), .RPT_DELAY(rpt_delay), .RPT_INTERVAL(rpt_interval),
    .KEY_CODING(key_coding), .LED_STB(led_stb), .LED_VAL(led_val),
    .CAPS(caps), .KANA(kana)
  );

  // One count per code delivered, key press or repeat.
  integer strobes = 0;
  always @(posedge clk) if (dut.key_stb) strobes <= strobes + 1;

  integer errors = 0;
  reg [8:0] v;
  integer n0;   // strobes at the start of a check ('before' is a keyword)

  // PS/2 codes, 9-bit {E0, code}
  localparam [8:0] SHIFT = 9'h012, CTRL = 9'h014, GRAPH = 9'h011, KANA = 9'h111,
                   ESC = 9'h076, BS = 9'h066, TAB = 9'h00d, BACKTICK = 9'h00e,
                   INS = 9'h170, DEL = 9'h171, HOME = 9'h16c, PGUP = 9'h17d,
                   PGDN = 9'h17a, UP = 9'h175, LEFT = 9'h16b, DOWN = 9'h172,
                   RIGHT = 9'h174, KEY_2 = 9'h01e, MINUS = 9'h04e, EQUALS = 9'h055,
                   BACKSLASH = 9'h05d, KEY_A = 9'h01c, RETURN = 9'h05a, F1 = 9'h005,
                   CAPSL = 9'h058, RO_MAIN = 9'h013, RO_ISO = 9'h061, END_K = 9'h169;

  task automatic ev(input [8:0] code, input press);
    begin
      @(negedge clk); ps2_key = {~ps2_key[10], press, code};
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic tap(input [8:0] code);
    begin ev(code, 1'b1); ev(code, 1'b0); end
  endtask

  // { $FD00 b7, $FD01 }
  // A $FD01 read in the E phase, as the CPU makes it, so it acknowledges the
  // code and the keyboard may present the next one.
  task automatic read_fd(output [8:0] d);
    begin
      @(negedge clk); rfd00n = 1'b0; #1 d[8] = mkdata[7]; rfd00n = 1'b1;
      eb = 1'b1; rfd01n = 1'b0;
      repeat (2) @(posedge clk);
      #1 d[7:0] = mkdata;
      @(negedge clk); rfd01n = 1'b1;
      repeat (2) @(posedge clk);
      @(negedge clk); eb = 1'b0;
    end
  endtask

  task automatic fail(input string what);
    begin errors = errors + 1; $display("FAIL %s", what); end
  endtask

  // Tap a key: exactly one code, and $FD01 still holds it after the release.
  task automatic expect_key(input [8:0] code, input [8:0] want, input string what);
    begin
      n0 = strobes;
      tap(code);
      read_fd(v);
      if (strobes != n0 + 1 || v !== want)
        fail($sformatf("%s: %0d code(s), $FD00b7:$FD01 = %03x, want 1 and %03x",
                       what, strobes - n0, v, want));
    end
  endtask

  task automatic expect_silent(input [8:0] code, input string what);
    reg [8:0] was;
    begin
      read_fd(was);
      n0 = strobes;
      tap(code);
      read_fd(v);
      if (strobes != n0 || v !== was)
        fail($sformatf("%s: %0d code(s), $FD01 %03x -> %03x, want none",
                       what, strobes - n0, was, v));
    end
  endtask

  // Scan mode: the make code is the key's physical number, the break the same
  // with b7 set, and both are delivered like any other key code.
  task automatic expect_scan(input [8:0] code, input [6:0] want, input string what);
    begin
      n0 = strobes;
      ev(code, 1'b1);
      read_fd(v);
      if (strobes != n0 + 1 || v !== {2'b00, want})
        fail($sformatf("%s make: %0d code(s), $FD00b7:$FD01 = %03x, want 1 and %03x",
                       what, strobes - n0, v, {2'b00, want}));
      n0 = strobes;
      ev(code, 1'b0);
      read_fd(v);
      if (strobes != n0 + 1 || v !== {1'b0, 1'b1, want})
        fail($sformatf("%s break: %0d code(s), $FD00b7:$FD01 = %03x, want 1 and %03x",
                       what, strobes - n0, v, {1'b0, 1'b1, want}));
    end
  endtask

  task automatic wait_ms(input integer ms);
    begin repeat (ms * 48000) @(posedge clk); end   // CLKSYS is 48 MHz
  endtask

  task automatic set_repeat_time(input [7:0] delay_10ms, input [7:0] interval_10ms);
    begin
      @(negedge clk); rpt_delay = delay_10ms; rpt_interval = interval_10ms; rpt_time_stb = 1'b1;
      @(negedge clk); rpt_time_stb = 1'b0;
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    resetn = 1'b1;
    repeat (4) @(posedge clk);

    read_fd(v);
    if (v !== 9'h0ff) fail($sformatf("power-on $FD00b7:$FD01 = %03x, want 0ff", v));

    // Plain EL and CLS: $05 and $0C in the character code table, System
    // Specifications 1.9.5 p.1-31. They sent $00.
    expect_key(PGUP, 9'h005, "PgUp = EL");
    expect_key(PGDN, 9'h00c, "PgDn = CLS");

    // The SHIFT layer for keys with no upper legend (1.9.6 p.1-32), ']' -> '}',
    // and the shifted cursor codes F-BASIC's sub-system acts on (Phase III
    // Table 3-6-1, printed p.220). All of these sent nothing.
    ev(SHIFT, 1'b1);
    expect_key(ESC,      9'h01b, "SHIFT+ESC");
    expect_key(BS,       9'h008, "SHIFT+BS");
    expect_key(TAB,      9'h009, "SHIFT+TAB");
    expect_key(BACKTICK, 9'h07d, "SHIFT+] = }");
    expect_key(INS,      9'h012, "SHIFT+INS");
    expect_key(DEL,      9'h07f, "SHIFT+DEL");
    expect_key(HOME,     9'h00b, "SHIFT+HOME");
    expect_key(PGUP,     9'h005, "SHIFT+EL");
    expect_key(PGDN,     9'h00c, "SHIFT+CLS");
    expect_key(UP,       9'h019, "SHIFT+UP");
    expect_key(LEFT,     9'h002, "SHIFT+LEFT");
    expect_key(DOWN,     9'h01a, "SHIFT+DOWN");
    expect_key(RIGHT,    9'h006, "SHIFT+RIGHT");
    expect_key(KEY_2,    9'h022, "SHIFT+2 = \"");
    ev(SHIFT, 1'b0);

    // CTRL gives the key's displayed code minus $40, and the control-mode
    // drawing (1.9.9 p.1-34) marks '^' and '\' (yen) -- not '-'.
    ev(CTRL, 1'b1);
    expect_key(EQUALS,    9'h01e, "CTRL+^ = RS");
    expect_key(BACKSLASH, 9'h01c, "CTRL+YEN = FS");
    expect_silent(MINUS,  "CTRL+-");
    expect_key(KEY_A,     9'h001, "CTRL+A");
    ev(CTRL, 1'b0);

    // ESC in the other modes (drawn on the GRAPH layout, 1.9.8 p.1-33).
    ev(GRAPH, 1'b1);
    expect_key(ESC, 9'h01b, "GRAPH+ESC");
    ev(GRAPH, 1'b0);
    tap(KANA);                                   // KANA locks on
    expect_key(ESC, 9'h01b, "KANA+ESC");
    ev(SHIFT, 1'b1);
    expect_key(ESC, 9'h01b, "KANA+SHIFT+ESC");
    ev(SHIFT, 1'b0);
    tap(KANA);                                   // and off
    expect_key(KEY_A, 9'h061, "a after KANA off");

    // The JIS ro key, phy $34 (XM7 norm/ctrl/graph/kana tables, CSP
    // keyboard_tables.h): it was not mapped at all. Main_MiSTer sends a USB JIS
    // ro as $13; ISO's extra key and End carry it too.
    expect_key(RO_MAIN, 9'h022, "ro (Main $13) = \"");
    expect_key(RO_ISO,  9'h022, "ro (ISO $61) = \"");
    expect_key(END_K,   9'h022, "ro (End) = \"");
    ev(SHIFT, 1'b1); expect_key(RO_MAIN, 9'h05f, "SHIFT+ro = _"); ev(SHIFT, 1'b0);
    ev(CTRL, 1'b1);  expect_key(RO_MAIN, 9'h01f, "CTRL+ro = US"); ev(CTRL, 1'b0);
    ev(GRAPH, 1'b1); expect_key(RO_MAIN, 9'h0e0, "GRAPH+ro"); ev(GRAPH, 1'b0);
    tap(KANA); expect_key(RO_MAIN, 9'h0db, "KANA+ro = ro"); tap(KANA);

    // CAP locks and swaps the letters' case, in the plain and SHIFT layers only.
    // It used to do nothing, so capitals needed SHIFT.
    if (caps !== 1'b0) fail("CAP not off at power-on");
    expect_silent(CAPSL, "CAP sends no code");
    if (caps !== 1'b1) fail("CAP did not lock on");
    expect_key(KEY_A, 9'h041, "CAP+a = A");
    expect_key(KEY_2, 9'h032, "CAP+2 = 2 (letters only)");
    ev(SHIFT, 1'b1); expect_key(KEY_A, 9'h061, "CAP+SHIFT+a = a"); ev(SHIFT, 1'b0);
    ev(CTRL, 1'b1);  expect_key(KEY_A, 9'h001, "CAP+CTRL+A = SOH"); ev(CTRL, 1'b0);
    tap(KANA); expect_key(KEY_A, 9'h0c1, "CAP+KANA+a = chi"); tap(KANA);
    tap(CAPSL);
    if (caps !== 1'b0) fail("CAP did not unlock");
    expect_key(KEY_A, 9'h061, "a after CAP off");

    // FM77AV encoder $02 sets the locks themselves: 00 CAP on, 01 off, 02 KANA on,
    // 03 off (77AVEMU fm77avkeyboard.cpp:590).
    @(negedge clk); led_val = 2'd0; led_stb = 1'b1; @(negedge clk); led_stb = 1'b0;
    if (caps !== 1'b1) fail("encoder $02 00 did not set CAP");
    @(negedge clk); led_val = 2'd2; led_stb = 1'b1; @(negedge clk); led_stb = 1'b0;
    if (kana !== 1'b1) fail("encoder $02 02 did not set KANA");
    @(negedge clk); led_val = 2'd3; led_stb = 1'b1; @(negedge clk); led_stb = 1'b0;
    @(negedge clk); led_val = 2'd1; led_stb = 1'b1; @(negedge clk); led_stb = 1'b0;
    if (caps !== 1'b0 || kana !== 1'b0) fail("encoder $02 01/03 did not clear CAP/KANA");

    // FM77AV scan code mode. A release reports, which the FM-7 code system
    // cannot do at all, and the modifier keys report as themselves.
    key_coding = 2'd2;
    expect_scan(KEY_A, 7'h1e, "scan A");
    expect_scan(F1,    7'h5d, "scan PF1");
    expect_scan(9'h075, 7'h3b, "scan keypad 8");
    expect_scan(SHIFT, 7'h53, "scan SHIFT (a modifier reports)");
    expect_scan(CTRL,  7'h52, "scan CTRL");
    expect_scan(RO_MAIN, 7'h34, "scan ro");
    expect_scan(CAPSL, 7'h55, "scan CAP");
    if (caps !== 1'b0) fail("CAP toggled in scan mode");

    // Codes that arrive before the CPU has read the last one wait their turn,
    // as 77AVEMU's keyCodeQueue (fm77avkeyboard.cpp:357-369) and CSP's key_fifo
    // hold them. A d-pad turn under "Joypad keys" is a break and a make 1 ms
    // apart; when the break was overwritten, the old direction stayed held in
    // the game until it was pressed again.
    ev(9'h075, 1'b1);          // keypad 8 down
    ev(9'h075, 1'b0);          // up, before anything was read
    ev(9'h074, 1'b1);          // keypad 6 down
    read_fd(v); if (v !== 9'h03b) fail($sformatf("queued 1: %03x, want 03b (KP8 make)", v));
    read_fd(v); if (v !== 9'h0bb) fail($sformatf("queued 2: %03x, want 0bb (KP8 break)", v));
    read_fd(v); if (v !== 9'h040) fail($sformatf("queued 3: %03x, want 040 (KP6 make)", v));
    if (dut.m132 !== 1'b0) fail("strobe still up with the queue empty");
    read_fd(v); if (v !== 9'h040) fail($sformatf("queue drained: $FD01 %03x, want it to hold 040", v));
    ev(9'h074, 1'b0);
    read_fd(v); if (v !== 9'h0c0) fail($sformatf("KP6 break: %03x, want 0c0", v));
    // Repeats of a held key do not stack up behind an unread code.
    ev(KEY_A, 1'b1);
    wait_ms(850);              // make, then repeats at 0.7 s and 0.77 s, none read
    ev(KEY_A, 1'b0);
    read_fd(v); if (v !== 9'h01e) fail($sformatf("held A: %03x, want 01e", v));
    read_fd(v); if (v !== 9'h09e) fail($sformatf("held A, next: %03x, want 09e (no repeats queued)", v));
    if (dut.m132 !== 1'b0) fail("repeats were queued");
    key_coding = 2'd0;
    expect_key(KEY_A, 9'h061, "a again once the coding is back to FM-7");
    // The FM-7 code system is unchanged: an unread code is overwritten.
    tap(KEY_A); tap(KEY_2);
    read_fd(v); if (v !== 9'h032) fail($sformatf("FM-7 mode a then 2: %03x, want 032", v));
    if (dut.m132 !== 1'b0) fail("FM-7 mode queued a code");

    // $FD01 keeps the last code after a release (FM-Techknow 5-1-5, p.118) --
    // expect_key reads it after the release -- but a reset puts back the
    // power-on value, as XM7's keyboard_reset does.
    expect_key(F1, 9'h101, "PF1");
    @(negedge clk); resetn = 1'b0;
    repeat (4) @(posedge clk);
    resetn = 1'b1;
    repeat (4) @(posedge clk);
    read_fd(v);
    if (v !== 9'h0ff) fail($sformatf("after reset $FD00b7:$FD01 = %03x, want 0ff", v));

    // Auto-repeat: the first repeat 0.7 s after the press (1.9.4 p.1-30).
    n0 = strobes;
    ev(KEY_A, 1'b1);
    wait_ms(690);
    if (strobes != n0 + 1) fail($sformatf("repeat inside 0.7 s: %0d codes", strobes - n0));
    wait_ms(20);
    if (strobes != n0 + 2) fail($sformatf("no repeat by 0.71 s: %0d codes", strobes - n0));
    ev(KEY_A, 1'b0);

    // FM77AV encoder $05 shortening the delay while a key is already past the
    // new value: the repeat is due at once, not after the counter wraps.
    set_repeat_time(8'd255, 8'd255);             // 2.55 s / 2.55 s
    n0 = strobes;
    ev(KEY_A, 1'b1);
    wait_ms(1000);
    set_repeat_time(8'd50, 8'd10);               // 0.5 s / 0.1 s
    wait_ms(50);
    if (strobes != n0 + 2)
      fail($sformatf("repeat time shortened mid-hold: %0d repeat(s) in 50 ms, want 1", strobes - n0 - 1));
    ev(KEY_A, 1'b0);
    set_repeat_time(8'd0, 8'd0);                 // back to 0.7 s / 0.07 s

    if (errors != 0) $fatal(1, "KEYBOARD TEST: %0d failure(s)", errors);
    $display("KEYBOARD TEST PASS");
    $finish;
  end
endmodule
