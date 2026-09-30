// line_buf_ram variant: extra read pipeline stage + zero-init (emulates
// possible silicon DPX9B latency / power-on-zero state)
module line_buf_ram #(
    parameter DEPTH = 16,
    parameter AW    = (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
    input  wire                          clk,
    input  wire                          clk_en,
    input  wire                          we,
    input  wire [AW-1:0]                 waddr,
    input  wire [8:0]                    wdata,
    input  wire                          re,
    input  wire [AW-1:0]                 raddr,
    output reg  [8:0]                    q
);
    (* ram_style = "block" *) reg [8:0] mem [0:DEPTH-1];
    reg [8:0] q2 = 9'd0;
    integer zi;
    initial begin
        q = 9'd0;
        for (zi = 0; zi < DEPTH; zi = zi + 1) mem[zi] = 9'd0;
    end
    always @(posedge clk) begin
        if (clk_en) begin
            if (we) mem[waddr] <= wdata;
            if (re) q2 <= mem[raddr];
            q <= q2;
        end
    end
endmodule
