// Auto-generated synchronous LUT twiddle ROM (fft64_cos.mem).
// Case-table (NOT a reg-array) so it can never infer a memory:
// inferred-RAM read wiring is broken on this GW2A-18C silicon
// (see imgwin_20k VALIDATION_LOG). q registers on clk_en & re.
module tw_rom_cos (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        re,
    input  wire [4:0]  raddr,
    output reg  [17:0] q
);
    reg [17:0] word;
    always @* begin
        case (raddr)
            5'd0 : word = 18'h07fff;
            5'd1 : word = 18'h07f62;
            5'd2 : word = 18'h07d8a;
            5'd3 : word = 18'h07a7d;
            5'd4 : word = 18'h07642;
            5'd5 : word = 18'h070e3;
            5'd6 : word = 18'h06a6e;
            5'd7 : word = 18'h062f2;
            5'd8 : word = 18'h05a82;
            5'd9 : word = 18'h05134;
            5'd10: word = 18'h0471d;
            5'd11: word = 18'h03c57;
            5'd12: word = 18'h030fc;
            5'd13: word = 18'h02528;
            5'd14: word = 18'h018f9;
            5'd15: word = 18'h00c8c;
            5'd16: word = 18'h00000;
            5'd17: word = 18'h0f374;
            5'd18: word = 18'h0e707;
            5'd19: word = 18'h0dad8;
            5'd20: word = 18'h0cf04;
            5'd21: word = 18'h0c3a9;
            5'd22: word = 18'h0b8e3;
            5'd23: word = 18'h0aecc;
            5'd24: word = 18'h0a57e;
            5'd25: word = 18'h09d0e;
            5'd26: word = 18'h09592;
            5'd27: word = 18'h08f1d;
            5'd28: word = 18'h089be;
            5'd29: word = 18'h08583;
            5'd30: word = 18'h08276;
            5'd31: word = 18'h0809e;
            default: word = 18'h00000;
        endcase
    end
    always @(posedge clk) begin
        if (clk_en && re) q <= word;
    end
endmodule
