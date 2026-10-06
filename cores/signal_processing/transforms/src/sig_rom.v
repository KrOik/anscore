// Synchronous-read initialized ROM (BSRAM with init or LUT-ROM fallback;
// either way functionally identical). Used for FFT twiddle tables.
module sig_rom #(
    parameter WIDTH = 18,
    parameter DEPTH = 32,
    parameter FILE  = "fft64_cos.mem"
)(
    input  wire             clk,
    input  wire             clk_en,
    input  wire             re,
    input  wire [(DEPTH == 1 ? 0 : ($clog2(DEPTH)-1)):0] raddr,
    output reg  [WIDTH-1:0] q
);

    (* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
    initial $readmemh(FILE, mem);

    always @(posedge clk) begin
        if (clk_en && re) q <= mem[raddr];
    end

endmodule
