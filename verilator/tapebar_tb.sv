// Directed checks for rtl/TAPEBAR.sv -- the tape status bar.
//
//   make tapebar-test
//
// TICK_HZ = 100 keeps every case short: the module only ever counts ticks
// against TICK_HZ, so nothing here depends on the real 9 us tick. The video
// is a small made-up raster (64 x 40 active, a pixel every third clock),
// which is enough to check the measuring, the box placement and the gating.
`timescale 1ns/1ns
module tapebar_tb;

reg         clk = 0;
reg         dl = 0, dl_wr = 0;
reg  [24:0] dl_addr = 0;
reg  [7:0]  dl_data = 0;
reg         loaded = 0, playing = 0, fast = 0, enable = 1;
reg  [31:0] position = 0;
reg         ce_pix = 0;
logic       hblank, vblank;
wire [23:0] rgb_out;

TAPEBAR #(.TICK_HZ(18'd100), .FACTOR(4'd3)) dut(
  .clk_sys(clk), .dl(dl), .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data),
  .loaded(loaded), .playing(playing), .fast(fast), .position(position),
  .clk_video(clk), .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank),
  .enable(enable), .rgb_in(24'hFFFFFF), .rgb_out(rgb_out));

always #5 clk = ~clk;

integer fails = 0, checks = 0;
task automatic check(input string what, input logic [63:0] got, input logic [63:0] want);
  checks++;
  if (got !== want) begin fails++; $display("FAIL %s: got %0h want %0h", what, got, want); end
endtask
task automatic clocks(input integer n); repeat (n) @(posedge clk); endtask

// One byte of the image, as hps_io delivers it.
task automatic put(input [24:0] a, input [7:0] d);
  @(posedge clk); dl_addr <= a; dl_data <= d; dl_wr <= 1;
  @(posedge clk); dl_wr <= 0;
endtask

// The test raster: VW x VH active pixels, a pixel every third clock.
localparam VW = 64, VH = 40, HT = 80, VT = 50;
integer vx = 0, vy = 0, ce_div = 0;
always @(posedge clk) begin
  ce_div <= ce_div == 2 ? 0 : ce_div + 1;
  ce_pix <= ce_div == 2;
  if (ce_pix) begin
    vx <= vx == HT - 1 ? 0 : vx + 1;
    if (vx == HT - 1) vy <= vy == VT - 1 ? 0 : vy + 1;
  end
end
always @* begin hblank = vx >= VW; vblank = vy >= VH; end

// rgb_out at active pixel (px, py) of the next frame.
task automatic pixel_at(input integer px, input integer py, output logic [23:0] c);
  @(posedge vblank); @(negedge vblank);
  forever begin
    @(posedge clk);
    if (dut.overlay.x == px[10:0] && dut.overlay.y == py[9:0] && !hblank && !vblank) begin
      c = rgb_out; return;
    end
  end
endtask

logic [23:0] c;
integer i;

initial begin
  // --- total time: summed from the duration bytes as the image arrives ---
  // 18-byte header, then 50 entries of (level, 200): 10000 ticks = 100 s.
  @(posedge clk); dl <= 1;
  for (i = 0; i < 18; i++) put(i, 8'h99);          // header bytes never count
  for (i = 0; i < 50; i++) begin put(18 + 2*i, 8'h80); put(19 + 2*i, 8'd200); end
  @(posedge clk); dl <= 0;
  clocks(400);
  check("length in ticks", dut.length, 10000);
  check("total 1:40", dut.status.total, 16'h0140);

  // A second download starts from zero, not on top of the first.
  @(posedge clk); dl <= 1;
  for (i = 0; i < 4; i++) begin put(18 + 2*i, 8'h00); put(19 + 2*i, 8'd25); end
  @(posedge clk); dl <= 0;
  clocks(50);
  check("length restarts", dut.length, 100);
  check("total 0:01", dut.status.total, 16'h0001);

  // Back to the 100 s tape for the rest.
  @(posedge clk); dl <= 1;
  for (i = 0; i < 50; i++) begin put(18 + 2*i, 8'h80); put(19 + 2*i, 8'd200); end
  @(posedge clk); dl <= 0;
  clocks(400);

  // --- elapsed time and fill follow the position ---
  loaded <= 1; playing <= 1;
  for (i = 1; i <= 2500; i++) begin @(posedge clk); position <= i; end
  clocks(4);
  check("elapsed 0:25", dut.status.elapsed, 16'h0025);
  check("fill 16 of 64", dut.status.fill, 16);   // 2500 / (10000/64 = 156)
  for (i = 2501; i <= 10000; i++) begin @(posedge clk); position <= i; end
  clocks(4);
  check("elapsed 1:40 at the end", dut.status.elapsed, 16'h0140);
  check("fill 64 at the end", dut.status.fill, 64);

  // --- rewind returns both to zero ---
  @(posedge clk); position <= 0;
  clocks(4);
  check("elapsed 0 after rewind", dut.status.elapsed, 0);
  check("fill 0 after rewind", dut.status.fill, 0);

  // --- the picture is measured ---
  repeat (3) @(posedge vblank);
  check("width measured", dut.overlay.width, VW);
  check("height measured", dut.overlay.height, VH);
  check("no doubling below 512 x 300", {dut.overlay.sx, dut.overlay.sy}, 0);

  // --- drawn only while loaded, playing and enabled ---
  // y0 = 40 - 18 - 4 = 18; (5, 19) is box background, (0, 0) is outside.
  pixel_at(5, 19, c);  check("box drawn while playing", c, 24'h000000);
  pixel_at(1, 1, c);   check("outside the box untouched", c, 24'hFFFFFF);
  playing <= 0; clocks(20);
  pixel_at(5, 19, c);  check("hidden when the deck stops", c, 24'hFFFFFF);
  playing <= 1; enable <= 0; clocks(20);
  pixel_at(5, 19, c);  check("hidden when Tape overlay is Off", c, 24'hFFFFFF);
  enable <= 1; loaded <= 0; clocks(20);
  pixel_at(5, 19, c);  check("hidden with no tape loaded", c, 24'hFFFFFF);

  $display("tapebar: %0d checks, %0d failures", checks, fails);
  if (fails) $fatal(1, "tapebar_tb FAILED");
  $finish;
end

initial begin #50_000_000; $fatal(1, "tapebar_tb timed out"); end
endmodule
