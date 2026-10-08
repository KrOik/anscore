// ---------------------------------------------------------------------------
// gw2a_ips_barrel_align : packaged, licensable wrapper for the ips_barrel_align core.
// Family path.  64-bit barrel shifter and bit-offset aligner for unaligned word extraction from a stream
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_barrel_align #(
    parameter WIDTH = 64,
    parameter MAXOFF = WIDTH / 8 - 1,
    parameter PLACE = MAXOFF + 1,
    parameter MARK_VALUE = 32'h5C1A_7E3D,
    parameter MARK_SHIFT = 0,
    parameter MARK_MASK = 32'h0000_00FF
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire [WIDTH-1:0] cur,
    input wire [WIDTH-1:0] nxt,
    input wire [2:0] amt,
    input wire [1:0] fmode,
    output wire [WIDTH-1:0] align_q,
    output wire [3:0] pos_q,
    output wire [WIDTH/8-1:0] drop_q,
    output wire drop_sticky,
    output wire [3:0] drop_beats,
    output wire [3:0] mark_hits,
    output wire mark_sticky,
    output wire cfg_error
);

    ips_barrel_align #(
        .WIDTH(WIDTH),
        .MAXOFF(MAXOFF),
        .PLACE(PLACE),
        .MARK_VALUE(MARK_VALUE),
        .MARK_SHIFT(MARK_SHIFT),
        .MARK_MASK(MARK_MASK)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .cur(cur),
        .nxt(nxt),
        .amt(amt),
        .fmode(fmode),
        .align_q(align_q),
        .pos_q(pos_q),
        .drop_q(drop_q),
        .drop_sticky(drop_sticky),
        .drop_beats(drop_beats),
        .mark_hits(mark_hits),
        .mark_sticky(mark_sticky),
        .cfg_error(cfg_error)
    );

endmodule
