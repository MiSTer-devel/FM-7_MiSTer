
// The core's audio sum: the YM2203's two halves, the speaker, the cassette
// bit and the relay click, into one signed 16-bit bus.
//
// This exists as a module because the arithmetic used to be hand-copied into
// FM-7_MiSTer.sv and verilator/sim.v, comment and all. A mix the simulator
// only has a COPY of is a mix the simulator cannot be trusted to measure, and
// the balance below is a thing that has to be measured.
//
//----------------------------------------------------------------------------
// The FM:SSG balance is jt12's own
//
// jt03 hands out its two halves separately -- `psg_snd` (SSG, 10 bits,
// unipolar, 0 = silence) and `fm_snd` (FM, signed 16 bits, 0 = silence) --
// and jt12 also states the ratio it intends between them, in
// rtl/jt12/jt12_top.v:482:
//
//     snd_left = fm_snd_left + { 1'b0, psg_snd[9:0], 5'd0 };
//
// FM at unity against the SSG shifted up by FIVE. What this core did instead
// was `fm_snd >>> 4` against `psg_snd << 4`: a sixteenth of the FM and half
// the SSG, so the two ended up a FACTOR OF EIGHT -- 18 dB -- away from the
// ratio the chip model's author calibrated. That is issue #1: "FM sound is
// present, but it's almost inaudible." A YM2203 has no rhythm section, so an
// FM-7 music driver puts its percussion on the SSG noise channel and its
// melody on FM; an SSG three times louder than the FM is heard exactly as
// reported, as drums over a barely audible tune.
//
// Both shifts are halved here (FM_SHIFT 1, SSG_SHIFT 4) to leave room under
// them for the three sources jt12 knows nothing about. The RATIO is jt12's,
// and the SSG's absolute level is unchanged from what shipped -- psg_snd << 4
// then and now -- so this commit moves the FM half and nothing else.
//
// Every reference puts FM at or above the SSG; none puts it below. Peak-to-
// peak of each half at its own full scale, FM : SSG --
//
//   jt12                65534 : 24480   2.70 : 1   jt12_top.v:482
//   fmgen / CSP         65534 : 16384   4.00 : 1   opna.cpp:165,387,
//                                                  psg.cpp:105
//   77AVEMU            3x4096 : 3x4096  1.00 : 1   ym2612.h:96, ay38910.h:21
//   this core, before    4095 : 12240   0.33 : 1
//   this core, now      32767 : 12240   2.68 : 1
//
// WHAT IS STILL UNKNOWN: nobody has measured a real FM77AV's board. On the
// part, the SSG is three analog pins and the FM goes out serially to a YM3014
// DAC, and what sets the balance is the resistor network those meet in. The
// three references span 1:1 to 4:1, so they do not settle it either. jt12's
// 2.7:1 is taken because jt12 is the model this core runs and its author
// calibrated the two halves against each other -- not because it is known to
// be the FM77AV's figure. An ear on hardware is the next step (TODO.md).
//
// The mix is deliberately the SAME on both machines. An FM-7 has an
// AY-3-8913 and no FM chip at all, so there is nothing there to balance --
// which is also why issue #1 is an FM77AV report: the FM-7's audio was, and
// is, the SSG term alone. Measured: the SSG term peaks at 8160 on Thexder
// (FM-7) and 8160 on Albatross (AV), and the change moved neither.
//
//----------------------------------------------------------------------------
// Silence is 0 and the bus is signed
//
// sys/audio_out.sv:217 hands the DAC `{~is_signed ^ cl[15], cl[14:0]}`, so for
// an UNSIGNED core it flips the top bit: unsigned 0 arrives as signed -32768.
// This core's silence was 0 and AUDIO_S was 0, so every sample it ever emitted
// carried a half-scale negative DC offset and the whole mix swung one way out
// of the bottom rail. AUDIO_S is 1 now and silence is a true zero.
//
// The SSG stays unipolar on top of that, which is not an oversight -- it is
// what jt12 does above, and what the part does: an AY-3-8913 sources current
// to ground, so its output has DC while it plays. Only the FM half is centred.
//
//----------------------------------------------------------------------------
// Headroom
//
// The five sources at once come to 46287 against a 32767 ceiling, so the sum
// SATURATES rather than wrapping. It only reaches that with the FM accumulator
// at its own clamp, all three SSG channels at amplitude 15, the speaker on and
// Tape Audio on together; a wrap there would be a full-scale pop, a clip is
// inaudible. The previous mix had no saturation and instead kept every source
// quiet enough that overflow was arithmetically impossible -- which is how the
// FM half ended up with 12 bits.
//
// Measured rather than derived, over 1500 frames of the loudest title to hand:
// Albatross on the AV reaches fm_snd +-25765, which is +-12883 here, over an
// SSG term peaking at 8160. Summed as if those coincided that is 21043, and
// with the speaker 29235, both under the ceiling. What the mix ACTUALLY
// reached is 16761 of 32767, because the peaks do not coincide -- so the
// saturation above never engaged on any of the four titles measured. Turning
// Tape Audio on during loud music could clip it; that is a tape monitor, used
// while a tape loads.
module AUDIOMIX(
  input                 tape_audio,   // OSD "Tape Audio": gates cassette + relay
  input        [ 9:0]   psg_snd,      // jt03 SSG mix, 0..765, 0 = silence
  input  signed [15:0]  fm_snd,       // jt03 FM mix, signed, 0 = silence
  input                 buzzer,       // $fd03 b0 speaker, 1 bit
  input                 cassette,     // cassette bit, already gated by motor
  input  signed [ 8:0]  relay_snd,    // relay click, signed, 0 when idle
  output signed [15:0]  audio
);

localparam FM_SHIFT    = 1;      // fm_snd >>> 1       +-16384
localparam SSG_SHIFT   = 4;      // psg_snd << 4         0..12240
localparam RELAY_SHIFT = 7;      // +-10 of recording  +-1280
localparam BUZZ_LEVEL  = 18'sd8192;
localparam TAPE_LEVEL  = 18'sd8192;

// 18 bits so the sum cannot overflow before it is clamped: the five terms
// span -17664 .. +46287.
wire signed [17:0] a_fm    = $signed({ {2{fm_snd[15]}}, fm_snd }) >>> FM_SHIFT;
wire signed [17:0] a_ssg   = $signed({ 8'd0, psg_snd }) <<< SSG_SHIFT;
wire signed [17:0] a_buz   = buzzer ? BUZZ_LEVEL : 18'sd0;
wire signed [17:0] a_cin   = (cassette & tape_audio) ? TAPE_LEVEL : 18'sd0;
wire signed [17:0] a_relay = tape_audio
                           ? ($signed({ {9{relay_snd[8]}}, relay_snd }) <<< RELAY_SHIFT)
                           : 18'sd0;

wire signed [17:0] sum = a_fm + a_ssg + a_buz + a_cin + a_relay;

assign audio = (sum >  18'sd32767) ?  16'sh7fff :
               (sum < -18'sd32768) ? 16'sh8000  : sum[15:0];

endmodule
