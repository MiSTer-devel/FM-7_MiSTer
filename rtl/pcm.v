// WIP


module pcm(
  input CLKSYS,
  input motor,
  output signed [8:0] relay_audio
);

reg [1:0] state; // 0 = off, 1 = relay on, 2 = relay off
reg old_motor_state;
reg [10:0] pcm_addr;
wire [7:0] off_sound;
wire [7:0] on_sound;
reg [10:0] stop;

always @(posedge CLKSYS)
  old_motor_state <= motor;

// 8000Hz clock
wire _8000Hz;
clk_en #(PCM_CLK) u_ck_en(.ref_clk(CLKSYS), .cen(_8000Hz));

// Both recordings sit on a 128 midpoint, not on zero: RELAY_ON.mem runs
// 119..134 and RELAY_OFF.mem 118..137, each about a mean of 127. Handing the
// raw byte to the audio sum as if 0 were its silence made every relay event a
// DC STEP of 128 -- which the old `relay_snd << 7` turned into 16384, thirteen
// times the amplitude of the +-10 rattle actually recorded, and half the sum's
// whole budget. Subtracting the midpoint leaves the recording and nothing
// else, and a true zero while no sample is playing.
wire [7:0] sample = state == 2'd1 ? on_sound : state == 2'd2 ? off_sound : 8'd128;
assign relay_audio = $signed({1'b0, sample}) - 9'sd128;

always @(posedge CLKSYS) begin
  if (motor == 0 && old_motor_state == 0) begin
    state <= 2'b0;
  end
  else if (old_motor_state == 1'b0 && motor == 1'b1) begin
    state <= 2'b1;
    stop <= stop - 11'd1;
    pcm_addr <= 11'd0;
  end
  else if (motor == 1'b0 && old_motor_state == 1'b1) begin
    state <= 2'd2;
    stop <= stop - 11'd1;
    pcm_addr <= 11'd0;
  end
  if (_8000Hz && stop > 11'd0) begin
    pcm_addr <= pcm_addr + 11'd1;
    stop <= stop - 11'd1;
  end
end

rom #("./audio/RELAY_OFF.mem", 11, 8) replay_off(
  .clk  ( CLKSYS    ),
  .addr ( pcm_addr  ),
  .dout ( off_sound ),
  .ce_n ( 1'b0      )
);

rom #("./audio/RELAY_ON.mem", 11, 8) replay_on(
  .clk  ( CLKSYS   ),
  .addr ( pcm_addr ),
  .dout ( on_sound ),
  .ce_n ( 1'b0     )
);

endmodule
