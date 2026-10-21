// ============================================================================
// nco.sv -- DSP-08 shared NCO for the carrier recovery loop.
//
//   32-bit phase accumulator + quarter-wave sine LUT producing cos_o and
//   sin_o (Q1.11, amplitude 2047) combinationally from the current phase.
//
//   On each clk edge with en=1:  phase <= phase + inc  (mod 2^32).
//   The wrap-around is intentional modular arithmetic, NOT an overflow bug:
//   phase is measured in cycles*2^32, so inc = (f/Fs) * 2^32.
//
//   cos_o = sin(phase + pi/2), sin_o = sin(phase); both are combinational
//   outputs of the phase register, so a sample captured in the same cycle
//   sees the pre-update phase (documented loop ordering).
//
//   LUT: 64-entry quarter wave, l[i] = round(2047*sin(2*pi*i/256)),
//   reconstructed to a 256-point full wave by quadrant symmetry.  Max LUT
//   error vs. ideal sine <= ~1.2e-3 of full scale (endpoint asymmetry
//   included).  Single clk, synchronous active-low rst_n.  No DSP blocks.
// ============================================================================
module nco (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,
    input  wire signed [31:0] inc,
    output reg         [31:0] phase,
    output wire signed [11:0] sin_o,
    output wire signed [11:0] cos_o
);

// Quarter-wave LUT: qlut[i] = round(2047*sin(2*pi*i/256)), i=0..63.
// Combinational ROM read -- maps to LUT fabric (no DSP, no BRAM).
reg [10:0] qlut [0:63];
initial begin
    qlut[ 0] = 11'd0;    qlut[ 1] = 11'd50;   qlut[ 2] = 11'd100;
    qlut[ 3] = 11'd151;  qlut[ 4] = 11'd201;  qlut[ 5] = 11'd251;
    qlut[ 6] = 11'd300;  qlut[ 7] = 11'd350;  qlut[ 8] = 11'd399;
    qlut[ 9] = 11'd449;  qlut[10] = 11'd497;  qlut[11] = 11'd546;
    qlut[12] = 11'd594;  qlut[13] = 11'd642;  qlut[14] = 11'd690;
    qlut[15] = 11'd737;  qlut[16] = 11'd783;  qlut[17] = 11'd830;
    qlut[18] = 11'd875;  qlut[19] = 11'd920;  qlut[20] = 11'd965;
    qlut[21] = 11'd1009; qlut[22] = 11'd1052; qlut[23] = 11'd1095;
    qlut[24] = 11'd1137; qlut[25] = 11'd1179; qlut[26] = 11'd1219;
    qlut[27] = 11'd1259; qlut[28] = 11'd1299; qlut[29] = 11'd1337;
    qlut[30] = 11'd1375; qlut[31] = 11'd1411; qlut[32] = 11'd1447;
    qlut[33] = 11'd1483; qlut[34] = 11'd1517; qlut[35] = 11'd1550;
    qlut[36] = 11'd1582; qlut[37] = 11'd1614; qlut[38] = 11'd1644;
    qlut[39] = 11'd1674; qlut[40] = 11'd1702; qlut[41] = 11'd1729;
    qlut[42] = 11'd1756; qlut[43] = 11'd1781; qlut[44] = 11'd1805;
    qlut[45] = 11'd1828; qlut[46] = 11'd1850; qlut[47] = 11'd1871;
    qlut[48] = 11'd1891; qlut[49] = 11'd1910; qlut[50] = 11'd1927;
    qlut[51] = 11'd1944; qlut[52] = 11'd1959; qlut[53] = 11'd1973;
    qlut[54] = 11'd1986; qlut[55] = 11'd1997; qlut[56] = 11'd2008;
    qlut[57] = 11'd2017; qlut[58] = 11'd2025; qlut[59] = 11'd2032;
    qlut[60] = 11'd2037; qlut[61] = 11'd2041; qlut[62] = 11'd2045;
    qlut[63] = 11'd2046;
end

wire [7:0] sa = phase[31:24];           // sine address
wire [7:0] ca = phase[31:24] + 8'd64;   // cosine = sine + 90 deg

function signed [11:0] sine8(input [7:0] a);
    reg [10:0] m;
    reg        ng;
    begin
        case (a[7:6])
            2'd0: begin m = qlut[a[5:0]];          ng = 1'b0; end
            2'd1: begin m = qlut[6'd63 - a[5:0]];  ng = 1'b0; end
            2'd2: begin m = qlut[a[5:0]];          ng = 1'b1; end
            default: begin m = qlut[6'd63 - a[5:0]];  ng = 1'b1; end
        endcase
        sine8 = ng ? -$signed({1'b0, m}) : $signed({1'b0, m});
    end
endfunction

assign sin_o = sine8(sa);
assign cos_o = sine8(ca);

always @(posedge clk) begin
    if (!rst_n)
        phase <= 32'd0;
    else if (en)
        phase <= phase + inc[31:0];   // intentional mod-2^32 wrap
end

endmodule
