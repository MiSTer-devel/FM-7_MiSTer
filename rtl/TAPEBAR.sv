// SPDX-License-Identifier: GPL-2.0-only
// Tape status bar: "TAPE > m:ss/ m:ss" and a progress bar in the bottom-left
// corner of the picture while the cassette plays. It never changes the
// machine: it is mixed into the RGB after the core and before the scaler.
//
// Ported from the Sharp X1 core (rtl/x1_tape_overlay.sv), which defines the
// look for every MiSTer computer core (tape-standard.md, rules 19-24). What
// differs here is the unit. The X1 plays a sampled TAP, so it counts samples;
// a T77 is a list of (level, duration) entries, so this counts the units
// t77_decode.v plays, against TICK_HZ (9 us, the format's unit) per second:
// the core plays the unit at 9.000 us (clocks.svh DIV_T77), so tape time is
// wall time at Normal.
//
// The total is summed while the image downloads, not scanned afterwards: every
// entry is a big-endian word, bit 15 the level and bits 14-0 the duration, after
// an 18-byte header, so the sum of the low 15 bits of each word from 18 up is
// the tape's length in ticks -- the same field t77_decode.v plays, so the bar
// fills to the end exactly when the decoder gets there. (Superseded: summing
// only the odd byte, which undercounted every entry of 256 units or more.)
//
// TAPEBAR_STATUS runs on the system clock and TAPEBAR_OVERLAY on the video
// clock, with a toggle handshake between them. On this core the two clocks are
// the same (CLK_VIDEO = clk_sys), so the handshake is only a two-cycle delay;
// it stays so the pair keeps working if the video clock ever separates.
`timescale 1ns/1ps
module TAPEBAR #(
    parameter [17:0] TICK_HZ = 18'd111111,  // 1 / 9 us, the T77 unit
    parameter [3:0]  FACTOR  = 4'd3          // turbo factor shown as "xN"
) (
    input  logic        clk_sys,
    // the tape image arriving over ioctl
    input  logic        dl,           // tape download in progress
    input  logic        dl_wr,
    input  logic [24:0] dl_addr,
    input  logic [7:0]  dl_data,
    // the deck
    input  logic        loaded,       // a tape image is in SDRAM
    input  logic        playing,      // t77_decode is sending entries
    input  logic        fast,         // turbo active (no turbo yet: tie 0)
    input  logic [31:0] position,     // ticks played since the last rewind
    // video
    input  logic        clk_video,
    input  logic        ce_pix,       // one-cycle pulse per pixel
    input  logic        hblank, vblank,
    input  logic        enable,       // OSD "Tape overlay"
    input  logic [23:0] rgb_in,
    output logic [23:0] rgb_out
);
    logic [31:0] length = 32'd0;
    logic        old_dl = 1'b0;
    logic  [6:0] dur_hi = 7'd0;
    always_ff @(posedge clk_sys) begin
        old_dl <= dl;
        if (dl && !old_dl) length <= 32'd0;
        else if (dl && dl_wr && dl_addr >= 25'd18) begin
            if (!dl_addr[0]) dur_hi <= dl_data[6:0];
            else             length <= length + {17'd0, dur_hi, dl_data};
        end
    end

    logic [41:0] word;
    logic        req, ack;

    TAPEBAR_STATUS status (
        .clk(clk_sys), .loaded(loaded), .playing(playing), .fast(fast),
        .position(position), .length(length), .hz(TICK_HZ),
        .status(word), .req(req), .ack(ack)
    );

    TAPEBAR_OVERLAY #(.FACTOR(FACTOR)) overlay (
        .clk(clk_video), .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank),
        .enable(enable), .status(word), .req(req), .ack(ack),
        .rgb_in(rgb_in), .rgb_out(rgb_out)
    );
endmodule

// Times and fill, on the system clock. `position` only steps by one or returns
// to zero (rewind), so elapsed time and fill are counted, never divided.
module TAPEBAR_STATUS (
    input  logic        clk,
    input  logic        loaded,
    input  logic        playing,
    input  logic        fast,
    input  logic [31:0] position,    // ticks played
    input  logic [31:0] length,      // ticks on the tape
    input  logic [17:0] hz,          // ticks per second
    output logic [41:0] status,      // held while req != ack
    output logic        req,
    input  logic        ack          // asynchronous; synchronised here
);
    logic [15:0] elapsed, total;     // BCD m1 m0 s1 s0
    logic [17:0] frac;
    logic [31:0] last_pos, last_len, rem, cell_count;
    logic [17:0] last_hz;
    logic [6:0]  fill;
    logic        computing;
    logic [1:0]  ack_sync;

    function automatic logic [15:0] bcd_tick(input logic [15:0] t);
        logic [15:0] n;
        n = t;
        if (t == 16'h9959) return t;                 // saturate at 99:59
        if (t[3:0] != 4'd9) n[3:0] = t[3:0] + 4'd1;
        else begin
            n[3:0] = 0;
            if (t[7:4] != 4'd5) n[7:4] = t[7:4] + 4'd1;
            else begin
                n[7:4] = 0;
                if (t[11:8] != 4'd9) n[11:8] = t[11:8] + 4'd1;
                else begin n[11:8] = 0; n[15:12] = t[15:12] + 4'd1; end
            end
        end
        return n;
    endfunction

    wire [31:0] cell_bits = length[31:6] == 0 ? 32'd1 : {6'd0, length[31:6]};
    wire [41:0] pack = {loaded, playing, fast, fill, elapsed, total};

    initial begin
        elapsed = 0; total = 0; frac = 0; last_pos = 0; last_len = 0; last_hz = 0;
        rem = 0; cell_count = 0; fill = 0; computing = 0; req = 0; status = 0; ack_sync = 0;
    end

    always_ff @(posedge clk) begin
        ack_sync <= {ack_sync[0], ack};
        last_pos <= position;
        if (position == 0 || position < last_pos) begin
            elapsed <= 0; frac <= 0; fill <= 0; cell_count <= 0;
        end else if (position != last_pos) begin
            if (frac + 18'd1 >= hz) begin frac <= 0; elapsed <= bcd_tick(elapsed); end
            else frac <= frac + 18'd1;
            if (cell_count + 32'd1 >= cell_bits) begin
                cell_count <= 0;
                if (fill != 7'd64) fill <= fill + 7'd1;
            end else cell_count <= cell_count + 32'd1;
        end
        // Total time: subtract one second of ticks per clock after the length
        // changes. It changes on every byte of a download and settles at the end.
        last_len <= length; last_hz <= hz;
        if (length != last_len || hz != last_hz) begin
            rem <= length; total <= 0; computing <= hz != 0;
        end else if (computing) begin
            if (rem >= {14'd0, hz}) begin rem <= rem - {14'd0, hz}; total <= bcd_tick(total); end
            else computing <= 0;
        end
        // Send a changed status once the previous one was taken.
        if (req == ack_sync[1] && pack != status) begin
            status <= pack;
            req <= !req;
        end
    end
endmodule

// The drawing, on the video clock. The picture is measured, not assumed: the
// active width and height are counted between blanking edges every frame, so
// the box follows FM-7 (640x200) and FM77AV (320x200 / 640x200) modes alike.
module TAPEBAR_OVERLAY #(
    parameter [3:0] FACTOR = 4'd3
) (
    input  logic        clk,
    input  logic        ce_pix,
    input  logic        hblank, vblank,
    input  logic        enable,
    input  logic [41:0] status,      // from TAPEBAR_STATUS, stable while req != ack
    input  logic        req,
    output logic        ack,
    input  logic [23:0] rgb_in,
    output logic [23:0] rgb_out
);
    localparam int CHARS = 21;
    logic [1:0]  req_sync;
    logic [41:0] shown;
    logic [10:0] x, width;
    logic [9:0]  y, height;
    logic        line_active, old_hblank, old_vblank;

    initial begin
        req_sync = 0; ack = 0; shown = 0; x = 0; y = 0; width = 0; height = 0;
        line_active = 0; old_hblank = 0; old_vblank = 0;
    end

    always_ff @(posedge clk) begin
        req_sync <= {req_sync[0], req};
        if (req_sync[1] != ack) begin shown <= status; ack <= req_sync[1]; end
        if (ce_pix) begin
            old_hblank <= hblank; old_vblank <= vblank;
            if (!hblank && !vblank) begin x <= x + 11'd1; line_active <= 1; end
            if (hblank && !old_hblank) begin
                if (line_active) begin width <= x; y <= y + 10'd1; end
                x <= 0; line_active <= 0;
            end
            if (vblank && !old_vblank) begin height <= y; y <= 0; end
        end
    end

    wire        visible = enable && shown[41] && shown[40];
    wire        fast = shown[39];
    wire [6:0]  fill = shown[38:32];
    wire [15:0] elapsed = shown[31:16], total = shown[15:0];
    // Double horizontally on 640-wide pictures and vertically on 400-line ones,
    // so the box is the same size on screen in every mode.
    wire        sx = width >= 11'd512, sy = height >= 10'd300;
    localparam [10:0] BOX_W = 11'd172;           // CHARS * 8 + 4
    localparam [9:0]  BOX_H = 10'd18;
    wire [10:0] x0 = 11'd4;
    wire [9:0]  y0 = height - (sy ? {BOX_H[8:0], 1'b0} : BOX_H) - 10'd4;
    wire [10:0] dx = x - x0;
    wire [9:0]  dy = y - y0;
    wire [10:0] lx = sx ? {1'b0, dx[10:1]} : dx;
    wire [9:0]  ly = sy ? {1'b0, dy[9:1]} : dy;
    wire        in_box = x >= x0 && y >= y0 && lx < BOX_W && ly < BOX_H;

    // Text row at ly 2..9, x 2..; codes 0-9 digits, 10 ':', 11 '/', 12 T,
    // 13 A, 14 P, 15 E, 16 x, 17 play, 18 space.
    wire [10:0] tx = lx - 11'd2;
    wire [9:0]  ty = ly - 10'd2;
    wire [4:0]  col = tx[7:3];
    function automatic logic [4:0] digit(input logic [3:0] d, input logic blank_zero);
        return blank_zero && d == 0 ? 5'd18 : {1'b0, d};
    endfunction
    logic [4:0] code;
    always_comb begin
        case (col)
            5'd0: code = 5'd12;  5'd1: code = 5'd13;  5'd2: code = 5'd14;  5'd3: code = 5'd15;
            5'd4: code = 5'd18;  5'd5: code = 5'd17;  5'd6: code = 5'd18;
            5'd7: code = digit(elapsed[15:12], 1'b1);  5'd8: code = {1'b0, elapsed[11:8]};
            5'd9: code = 5'd10;  5'd10: code = {1'b0, elapsed[7:4]};  5'd11: code = {1'b0, elapsed[3:0]};
            5'd12: code = 5'd11;
            5'd13: code = digit(total[15:12], 1'b1);  5'd14: code = {1'b0, total[11:8]};
            5'd15: code = 5'd10;  5'd16: code = {1'b0, total[7:4]};  5'd17: code = {1'b0, total[3:0]};
            5'd18: code = 5'd18;
            5'd19: code = fast ? 5'd16 : 5'd18;  5'd20: code = fast ? {1'b0, FACTOR} : 5'd18;
            default: code = 5'd18;
        endcase
    end
    function automatic logic [7:0] glyph(input logic [4:0] c, input logic [2:0] r);
        logic [63:0] g;
        case (c)
            5'd0:  g = 64'h3C666E7666663C00;  5'd1:  g = 64'h1838181818187E00;
            5'd2:  g = 64'h3C66060C30607E00;  5'd3:  g = 64'h3C66061C06663C00;
            5'd4:  g = 64'h0C1C3C6C7E0C0C00;  5'd5:  g = 64'h7E607C0606663C00;
            5'd6:  g = 64'h1C30607C66663C00;  5'd7:  g = 64'h7E060C1830303000;
            5'd8:  g = 64'h3C66663C66663C00;  5'd9:  g = 64'h3C66663E060C3800;
            5'd10: g = 64'h0018180018180000;  5'd11: g = 64'h02060C1830604000;
            5'd12: g = 64'h7E18181818181800;  5'd13: g = 64'h183C66667E666600;
            5'd14: g = 64'h7C66667C60606000;  5'd15: g = 64'h7E60607C60607E00;
            5'd16: g = 64'h0000663C183C6600;  5'd17: g = 64'h4060707870604000;
            default: g = 64'h0;
        endcase
        return g[63 - 8 * r -: 8];
    endfunction
    wire [7:0] glyph_row = glyph(code, ty[2:0]);
    wire text_on = ty < 10'd8 && tx < 11'd168 && glyph_row[3'd7 - tx[2:0]];
    // Progress bar at ly 12..15, 128 px for 64 steps.
    wire bar_area = ly >= 10'd12 && ly < 10'd16 && lx >= 11'd2 && lx < 11'd130;
    wire bar_on = bar_area && (lx - 11'd2) < {3'd0, fill, 1'b0};

    always_comb begin
        rgb_out = rgb_in;
        if (visible && in_box)
            rgb_out = text_on ? 24'hFFFFFF : bar_on ? 24'h44CC44 : bar_area ? 24'h333333 : 24'h000000;
    end
endmodule
