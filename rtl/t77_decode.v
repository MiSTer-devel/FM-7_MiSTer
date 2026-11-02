
module t77_decode(
  input CLKSYS,
  input start,
  input [15:0] data,
  input data_stb,
  input rewind,
  // The main CPU is on its 3x tape-turbo leg (CLKCTRL turbo_on): play the
  // tape 3x as well, so the loader's loops see the same pulse widths.
  input fast,
  input [24:0] image_size,   // bytes loaded over ioctl; 0 = unknown
  output eot,                // end of tape reached
  output reg [24:0] sdram_addr,
  output reg sdram_rd,
  output sout,
  // For the tape status bar (TAPEBAR.sv): whether entries are being played,
  // and how many T77 units (clocks.svh DIV_T77) have played since the last rewind -- the same
  // unit as the duration bytes the bar sums for the total.
  output playing,
  output reg [31:0] position = 32'd0
);

reg clk_tick = 0;
reg pstart;
reg [15:0] counter = 0;
reg s;
reg [14:0] len;
reg sending;
reg next_s;
reg [14:0] next_len;
reg next_valid;
reg fetch_next;
// Start past the 18-byte XM7 header. The final two bytes are header metadata
// and are part of the file header, not a tape segment.
reg [24:0] addr = 25'd18;
reg [15:0] init;

assign sout = s;

// A T77 entry is ONE big-endian 16-bit word: bit 15 the level, bits 14-0 the
// duration in 9 us units (XM7 tapelp.c: dat = high*256 + low, tape_in =
// dat > $7fff, count = dat & $7fff; CSP datarec.cpp load_t77_image the same).
// The SDRAM presents the even (high) byte in data[7:0].
//
// (Superseded decode: "level byte, duration byte; level bytes below $40 are
// low, $7f/$ff is long silence", duration = the low byte alone. It played
// every entry of 256 units (2.3 ms) or more short and could flip a long low
// to high. Data pulses are under 128 units, so most loads survived it; Killer
// Station did not -- its tape ran ahead of the loader, which then missed the
// 1000 zero bytes before its sync and framed the $FF as $DF.)
wire decoded_s = data[7];
wire [14:0] decoded_len = { data[6:0], data[15:8] };

`ifdef DEBUG_TAPE
reg [24:0] dbg_entries   = 0;   // entries latched
reg [31:0] dbg_ticks     = 0;   // sum of the `len` values we loaded
reg [31:0] dbg_tick_count = 0;  // clk_tick periods actually elapsed
always @(posedge clk_tick) dbg_tick_count <= dbg_tick_count + 32'd1;
`endif

// Without this the address counter ran forever: a 238 KB image played out
// and then kept reading whatever else happened to be in SDRAM. image_size
// is latched from the ioctl download by the top level.
assign eot = (image_size != 25'd0) && (addr >= image_size);

// 2*(71+1)/48 MHz = 3.000 us, exactly a third of DIV_T77's 9.000 us.
wire [15:0] div_tick = fast ? 16'd71 : DIV_T77;
always @(posedge CLKSYS) begin
  if (counter >= div_tick) begin
    counter <= 16'd0;
    clk_tick <= ~clk_tick;
  end
  else begin
    counter <= counter + 16'd1;
  end
end

always @(posedge CLKSYS) begin
  pstart <= start;
  if (~pstart & start) begin
    init <= 16'h4000;
    $display("--------- motor on ---------");
  end
  if (~start & pstart) begin
    sending <= 1'b0;
    $display("--------- motor off---------");
  end
  if (init) begin
    init <= init - 16'h1;
    if (init == 16'h1) sending <= 1'b1;
  end
end

// The decoder below acts on every rising edge of clk_tick while sending and not
// at the end; this is that edge, one CLKSYS cycle early, counted in CLKSYS.
assign playing = sending & ~eot;
wire tick_t77 = (counter >= div_tick) && !clk_tick;
always @(posedge CLKSYS) begin
  if (rewind) position <= 32'd0;
  else if (tick_t77 && playing) position <= position + 32'd1;
end

always @(posedge clk_tick, posedge rewind) begin
  if (rewind) begin
    addr <= 25'd18;
    sdram_addr <= 25'd18;
    sdram_rd <= 1'b0;
    len <= 15'd0;
    next_valid <= 1'b0;
    fetch_next <= 1'b0;
  end
  else begin
    if (sdram_rd) begin
      if (data_stb) begin
        sdram_rd <= 1'b0;
        if (fetch_next) begin
          // Prefetches complete while the current segment is still running.
          // If the boundary is already due, consume the just-arrived entry
          // directly; otherwise retain it for the exact boundary below.
          if (len == 15'd1) begin
            s <= decoded_s;
            len <= decoded_len;
            next_valid <= 1'b0;
          end
          else begin
            next_s <= decoded_s;
            next_len <= decoded_len;
            next_valid <= 1'b1;
          end
        end
        else begin
          s <= decoded_s;
          len <= decoded_len;
        end
`ifdef DEBUG_TAPE
        // Every entry as it is actually latched, against what the file holds.
        // `len` is in 9.125 us ticks; a 1200 baud half-bit is ~47 and a 2400
        // baud half-bit is ~25, so anything near 0 means the word is wrong.
        dbg_entries <= dbg_entries + 25'd1;
        dbg_ticks   <= dbg_ticks + { 17'd0, decoded_len };
        if (dbg_entries < 25'd24)
          $display("T77 entry %0d addr=$%06x data=$%04x -> level=%0d len=%0d",
                   dbg_entries, sdram_addr, data,
                   decoded_s, decoded_len);
        if (eot)
          $display("T77SUM entries=%0d summed_len=%0d ticks_elapsed=%0d",
                   dbg_entries, dbg_ticks, dbg_tick_count);
`endif
      end

      // Count down the current segment even while a prefetch is in flight.
      // This prevents the SDRAM round trip from stretching every T77 level.
      if (len > 15'd1)
        len <= len - 15'd1;
      else if (len == 15'd1 && !data_stb && next_valid) begin
        s <= next_s;
        len <= next_len;
        next_valid <= 1'b0;
      end
    end
    else if (sending && ~eot) begin
      if (len > 15'd1) begin
        // Four 9-us ticks leave ample time for the SDRAM read to complete.
        if (!next_valid && len <= 15'd4) begin
          sdram_addr <= addr;
          sdram_rd <= 1'b1;
          fetch_next <= 1'b1;
          addr <= addr + 25'd2;
        end
        len <= len - 15'd1;
      end
      else if (len == 15'd1 && next_valid) begin
        s <= next_s;
        len <= next_len;
        next_valid <= 1'b0;
      end
      else if (len == 15'd1) begin
        len <= 15'd0;
      end
      else if (next_valid) begin
        s <= next_s;
        len <= next_len;
        next_valid <= 1'b0;
      end
      else begin
        sdram_addr <= addr;
        sdram_rd <= 1'b1;
        fetch_next <= 1'b0;
        addr <= addr + 25'd2;
      end
    end
  end
end


endmodule
