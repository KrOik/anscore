// ============================================================================
// hist256: 256-bin histogram over 8-bit samples.
//   start  -> clear sweep (256 clk_en beats, busy=1), zeroes counts + total.
//   in_valid/bin -> 2-beat read-modify-write accumulate in BSRAM.
//   rd_en/rd_addr -> registered readout (q valid 1 clk_en beat later).
//   total: 24-bit frame sample count.
//
// Back-to-back same-bin hazard: a write commits at the same posedge that the
// NEXT sample's sync read captures, so a read issued one beat after a same-bin
// write would return stale data. Solved by 1-deep forwarding: the last
// committed (addr,count) is replayed whenever the current bin matches; since
// it is the most recent write, forwarded data always equals RAM content.
// ============================================================================
module hist256 #(
    parameter CW = 16               // count width (<=18 for BSRAM)
) (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output wire        busy,
    input  wire        in_valid,
    input  wire [7:0]  bin,
    output reg  [23:0] total,
    input  wire        rd_en,
    input  wire [7:0]  rd_addr,
    output wire [CW-1:0] rd_data
);

reg        clearing;
reg [8:0]  clr;
reg        v1;
reg [7:0]  bin1;
reg        fwd_v;
reg [7:0]  fwd_addr;
reg [CW-1:0] fwd_cnt;

wire [17:0] q18;
wire [CW-1:0] q = q18[CW-1:0];
wire [CW-1:0] base = (fwd_v && (fwd_addr == bin1)) ? fwd_cnt : q;
wire [CW-1:0] ncount = base + {{(CW-1){1'b0}}, 1'b1};

wire        ram_we    = clearing ? !clr[8] : v1;
wire [7:0]  ram_waddr = clearing ? clr[7:0] : bin1;
wire [17:0] ram_wdata = clearing ? 18'd0 : { {(18-CW){1'b0}}, ncount };
wire        ram_re    = !clearing && (in_valid || rd_en);
wire [7:0]  ram_raddr = in_valid ? bin : rd_addr;

assign rd_data = q;
assign busy = clearing;

sig_sdp_ram #(.WIDTH(18), .DEPTH(256)) binram (
    .clk(clk), .clk_en(clk_en),
    .we(ram_we), .waddr(ram_waddr), .wdata(ram_wdata),
    .re(ram_re), .raddr(ram_raddr), .q(q18)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        clearing <= 1'b0; clr <= 9'd0;
        v1 <= 1'b0; bin1 <= 8'd0;
        fwd_v <= 1'b0; fwd_addr <= 8'd0; fwd_cnt <= {CW{1'b0}};
        total <= 24'd0;
    end else if (clk_en) begin
        v1 <= 1'b0;
        if (clearing) begin
            if (clr[8]) clearing <= 1'b0;
            else        clr <= clr + 9'd1;
        end else begin
            if (start) begin
                clearing <= 1'b1; clr <= 9'd0;
                fwd_v <= 1'b0; total <= 24'd0;
            end else begin
                if (in_valid) begin
                    bin1 <= bin; v1 <= 1'b1;
                end
                if (v1) begin
                    fwd_v <= 1'b1; fwd_addr <= bin1; fwd_cnt <= ncount;
                    total <= total + 24'd1;
                end
            end
        end
    end
end

endmodule
