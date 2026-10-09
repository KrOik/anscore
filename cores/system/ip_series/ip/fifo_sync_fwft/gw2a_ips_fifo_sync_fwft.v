// ---------------------------------------------------------------------------
// gw2a_ips_fifo_sync_fwft : packaged, licensable wrapper for the ips_fifo_sync_fwft core.
// Family path.  Synchronous FIFO, first-word-fall-through output, concurrent read/write, level and programmatic flag watermarks
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_fifo_sync_fwft #(
    parameter DATA_W = 8,
    parameter DEPTH = 16
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire wr_req,
    input wire [DATA_W-1:0] wdata,
    input wire rd_req,
    input wire [($clog2(DEPTH)):0] wm_hi,
    input wire [($clog2(DEPTH)):0] wm_lo,
    output wire [DATA_W-1:0] rdata,
    output wire full,
    output wire empty,
    output wire [($clog2(DEPTH)):0] level,
    output wire flag_hi,
    output wire flag_lo,
    output wire ov_flag,
    output wire uf_flag,
    output wire [3:0] ov_count,
    output wire [3:0] uf_count
);

    ips_fifo_sync_fwft #(
        .DATA_W(DATA_W),
        .DEPTH(DEPTH)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .wr_req(wr_req),
        .wdata(wdata),
        .rd_req(rd_req),
        .wm_hi(wm_hi),
        .wm_lo(wm_lo),
        .rdata(rdata),
        .full(full),
        .empty(empty),
        .level(level),
        .flag_hi(flag_hi),
        .flag_lo(flag_lo),
        .ov_flag(ov_flag),
        .uf_flag(uf_flag),
        .ov_count(ov_count),
        .uf_count(uf_count)
    );

endmodule
