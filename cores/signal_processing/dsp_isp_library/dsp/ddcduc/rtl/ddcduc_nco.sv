// ============================================================================
// ddcduc_nco.sv -- shared NCO/DDS for the DSP-03 DDC/DUC chains.
//
//   32-bit phase accumulator.  On each `step` cycle the phase advances by
//   the runtime `phase_inc`; a `load` pulse synchronously loads
//   `phase_init` (cfg commit path, has priority over step).  sin/cos outputs
//   are COMBINATIONAL reads of the phase register *before* this cycle's
//   increment, so beat k sees phase = init + k*inc (mod 2**32) -- the models
//   in models/model.py implement exactly this.
//
//   Waveform: quarter-wave sine case-ROM, 128 entries covering [0, pi/2),
//   entry i = round(32767*sin(pi*i/256)), i.e. 9-bit phase resolution
//   (2 quadrant + 7 table bits).  sin = qw(phase[31:23]);
//   cos = qw(phase[31:23]+9'd128).  Worst-case sine approximation error is
//   0.0123 of full scale (~ -38.2 dBc spur bound; models/model.py
//   nco_spur_bound()).  There is deliberately no interpolation so the NCO
//   costs zero DSP cells.
//
//   The case table (not a reg array) follows the tw_rom_cos.v precedent in
//   cores/signal_processing/transforms: inferred-RAM read wiring is unreliable on
//   GW2A-18C, so this maps to LUT logic deterministically.
//
//   Single clk, synchronous active-low rst_n.  Architecture reused from
//   cores/signal_processing/dsp/src/dds_nco.v (32-bit accumulator + sine LUT) with the
//   legacy async-reset/clk_en contract replaced by the goal.md sync-reset
//   Stream-era contract and a quadrature (sin+cos) output pair.
// ============================================================================
module ddcduc_nco (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load,        // synchronous load of phase_init
    input  wire        step,        // phase <= phase + phase_inc
    input  wire [31:0] phase_inc,
    input  wire [31:0] phase_init,
    output wire signed [15:0] sin_out,
    output wire signed [15:0] cos_out,
    output wire [31:0] phase_out
);
    reg [31:0] phase;
    assign phase_out = phase;

    // Quarter-wave sine: a[8:7]=quadrant, a[6:0]=offset into the wave.
    //   q0: +T[o]   q1: +T[127-o]   q2: -T[o]   q3: -T[127-o]
    function signed [15:0] qw16;
        input [8:0] a;
        reg sign;
        reg [6:0] o;
        reg [15:0] t;
        begin
            sign = a[8];
            o = a[7] ? (7'd127 - a[6:0]) : a[6:0];
            case (o)
      7'd0  : t = 16'sd0     ;
      7'd1  : t = 16'sd402   ;
      7'd2  : t = 16'sd804   ;
      7'd3  : t = 16'sd1206  ;
      7'd4  : t = 16'sd1608  ;
      7'd5  : t = 16'sd2009  ;
      7'd6  : t = 16'sd2410  ;
      7'd7  : t = 16'sd2811  ;
      7'd8  : t = 16'sd3212  ;
      7'd9  : t = 16'sd3612  ;
      7'd10 : t = 16'sd4011  ;
      7'd11 : t = 16'sd4410  ;
      7'd12 : t = 16'sd4808  ;
      7'd13 : t = 16'sd5205  ;
      7'd14 : t = 16'sd5602  ;
      7'd15 : t = 16'sd5998  ;
      7'd16 : t = 16'sd6393  ;
      7'd17 : t = 16'sd6786  ;
      7'd18 : t = 16'sd7179  ;
      7'd19 : t = 16'sd7571  ;
      7'd20 : t = 16'sd7962  ;
      7'd21 : t = 16'sd8351  ;
      7'd22 : t = 16'sd8739  ;
      7'd23 : t = 16'sd9126  ;
      7'd24 : t = 16'sd9512  ;
      7'd25 : t = 16'sd9896  ;
      7'd26 : t = 16'sd10278 ;
      7'd27 : t = 16'sd10659 ;
      7'd28 : t = 16'sd11039 ;
      7'd29 : t = 16'sd11417 ;
      7'd30 : t = 16'sd11793 ;
      7'd31 : t = 16'sd12167 ;
      7'd32 : t = 16'sd12539 ;
      7'd33 : t = 16'sd12910 ;
      7'd34 : t = 16'sd13279 ;
      7'd35 : t = 16'sd13645 ;
      7'd36 : t = 16'sd14010 ;
      7'd37 : t = 16'sd14372 ;
      7'd38 : t = 16'sd14732 ;
      7'd39 : t = 16'sd15090 ;
      7'd40 : t = 16'sd15446 ;
      7'd41 : t = 16'sd15800 ;
      7'd42 : t = 16'sd16151 ;
      7'd43 : t = 16'sd16499 ;
      7'd44 : t = 16'sd16846 ;
      7'd45 : t = 16'sd17189 ;
      7'd46 : t = 16'sd17530 ;
      7'd47 : t = 16'sd17869 ;
      7'd48 : t = 16'sd18204 ;
      7'd49 : t = 16'sd18537 ;
      7'd50 : t = 16'sd18868 ;
      7'd51 : t = 16'sd19195 ;
      7'd52 : t = 16'sd19519 ;
      7'd53 : t = 16'sd19841 ;
      7'd54 : t = 16'sd20159 ;
      7'd55 : t = 16'sd20475 ;
      7'd56 : t = 16'sd20787 ;
      7'd57 : t = 16'sd21096 ;
      7'd58 : t = 16'sd21403 ;
      7'd59 : t = 16'sd21705 ;
      7'd60 : t = 16'sd22005 ;
      7'd61 : t = 16'sd22301 ;
      7'd62 : t = 16'sd22594 ;
      7'd63 : t = 16'sd22884 ;
      7'd64 : t = 16'sd23170 ;
      7'd65 : t = 16'sd23452 ;
      7'd66 : t = 16'sd23731 ;
      7'd67 : t = 16'sd24007 ;
      7'd68 : t = 16'sd24279 ;
      7'd69 : t = 16'sd24547 ;
      7'd70 : t = 16'sd24811 ;
      7'd71 : t = 16'sd25072 ;
      7'd72 : t = 16'sd25329 ;
      7'd73 : t = 16'sd25582 ;
      7'd74 : t = 16'sd25832 ;
      7'd75 : t = 16'sd26077 ;
      7'd76 : t = 16'sd26319 ;
      7'd77 : t = 16'sd26556 ;
      7'd78 : t = 16'sd26790 ;
      7'd79 : t = 16'sd27019 ;
      7'd80 : t = 16'sd27245 ;
      7'd81 : t = 16'sd27466 ;
      7'd82 : t = 16'sd27683 ;
      7'd83 : t = 16'sd27896 ;
      7'd84 : t = 16'sd28105 ;
      7'd85 : t = 16'sd28310 ;
      7'd86 : t = 16'sd28510 ;
      7'd87 : t = 16'sd28706 ;
      7'd88 : t = 16'sd28898 ;
      7'd89 : t = 16'sd29085 ;
      7'd90 : t = 16'sd29268 ;
      7'd91 : t = 16'sd29447 ;
      7'd92 : t = 16'sd29621 ;
      7'd93 : t = 16'sd29791 ;
      7'd94 : t = 16'sd29956 ;
      7'd95 : t = 16'sd30117 ;
      7'd96 : t = 16'sd30273 ;
      7'd97 : t = 16'sd30424 ;
      7'd98 : t = 16'sd30571 ;
      7'd99 : t = 16'sd30714 ;
      7'd100: t = 16'sd30852 ;
      7'd101: t = 16'sd30985 ;
      7'd102: t = 16'sd31113 ;
      7'd103: t = 16'sd31237 ;
      7'd104: t = 16'sd31356 ;
      7'd105: t = 16'sd31470 ;
      7'd106: t = 16'sd31580 ;
      7'd107: t = 16'sd31685 ;
      7'd108: t = 16'sd31785 ;
      7'd109: t = 16'sd31880 ;
      7'd110: t = 16'sd31971 ;
      7'd111: t = 16'sd32057 ;
      7'd112: t = 16'sd32137 ;
      7'd113: t = 16'sd32213 ;
      7'd114: t = 16'sd32285 ;
      7'd115: t = 16'sd32351 ;
      7'd116: t = 16'sd32412 ;
      7'd117: t = 16'sd32469 ;
      7'd118: t = 16'sd32521 ;
      7'd119: t = 16'sd32567 ;
      7'd120: t = 16'sd32609 ;
      7'd121: t = 16'sd32646 ;
      7'd122: t = 16'sd32678 ;
      7'd123: t = 16'sd32705 ;
      7'd124: t = 16'sd32728 ;
      7'd125: t = 16'sd32745 ;
      7'd126: t = 16'sd32757 ;
      7'd127: t = 16'sd32765 ;
                default: t = 16'sd0;
            endcase
            qw16 = sign ? -t : t;
        end
    endfunction

    assign sin_out = qw16(phase[31:23]);
    assign cos_out = qw16(phase[31:23] + 9'd128);   // cos(x)=sin(x+pi/2)

    always @(posedge clk) begin
        if (!rst_n)       phase <= 32'd0;
        else if (load)    phase <= phase_init;
        else if (step)    phase <= phase + phase_inc;
    end
endmodule
