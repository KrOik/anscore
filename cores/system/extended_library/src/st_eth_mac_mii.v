// ============================================================================
// st_eth_mac_mii -- selftest cell for eth_mac_mii (wave2 contract).
//
// Four frames through the internal MII loopback:
//   F0 dest=our MAC  len=60  type=0800 payload i*7+3        (exact min frame)
//   F1 dest=our MAC  len=114 type=86DD payload i*9+0x42     (long frame)
//   F2 dest=other    len=60  payload 0xFF-i                 (MAC mismatch)
//   F3 dest=bcast    len=20  payload i*5+7                  (zero-pad to 60)
//
// Fold stream per frame:
//   every received post-SFD byte (dest .. last FCS byte, incl pad),
//   then rx_len[7:0], then status = {5'b0, match, len_ok, crc_ok}.
// ============================================================================
module st_eth_mac_mii (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);

`include "w2_fnv.vh"

localparam [31:0] EXP = 32'h7DC3E176;   // golden_comm.py: MAC DIGEST
localparam [47:0] OUR_MAC = 48'h021122334455;

// frame source byte table ----------------------------------------------------
reg [1:0] fidx;

function [7:0] fr_b;
    input  [1:0]  f;
    input  [10:0] i;
    reg [111:0] hdr;                    // {dest[47:0], src[47:0], type[15:0]}
    reg [7:0]   pi;
    begin
        case (f)
            2'd2:    hdr = {48'h123456789ABC, 48'hAABBCCDDEEFF, 16'h0800};
            2'd3:    hdr = {48'hFFFFFFFFFFFF, 48'hAABBCCDDEEFF, 16'h0800};
            2'd1:    hdr = {OUR_MAC,          48'hAABBCCDDEEFF, 16'h86DD};
            default: hdr = {OUR_MAC,          48'hAABBCCDDEEFF, 16'h0800};
        endcase
        pi = (i - 11'd14);
        if (i < 11'd14) fr_b = hdr[(11'd13 - i) * 8 +: 8];
        else case (f)
            2'd0:    fr_b = (pi << 3) - pi + 8'd3;          // i*7+3
            2'd1:    fr_b = (pi << 3) + pi + 8'h42;         // i*9+0x42
            2'd2:    fr_b = 8'hFF - pi;                     // 0xFF-i
            default: fr_b = (pi << 2) + pi + 8'd7;          // i*5+7
        endcase
    end
endfunction

function [10:0] fr_len;
    input [1:0] f;
    begin
        case (f)
            2'd0:    fr_len = 11'd60;
            2'd1:    fr_len = 11'd114;
            2'd2:    fr_len = 11'd60;
            default: fr_len = 11'd20;
        endcase
    end
endfunction

// DUT ------------------------------------------------------------------------
reg         tx_start;
wire        tx_busy, tx_done;
wire [10:0] tx_bidx;
wire        rx_bv, rx_frm_v, rx_crc_ok, rx_match;
wire [7:0]  rx_byte;
wire [10:0] rx_len;

eth_mac_mii #(.MAC_ADDR(OUR_MAC)) dut (
    .clk(clk), .clk_en(clk_en || !rst_n), .rst_n(rst_n),
    .mii_tx_en(), .mii_txd(), .mii_rx_dv(1'b0), .mii_rxd(4'd0),
    .loopback(1'b1),
    .tx_start(tx_start), .tx_len(fr_len(fidx)), .tx_bidx(tx_bidx),
    .tx_byte(fr_b(fidx, tx_bidx)),
    .tx_busy(tx_busy), .tx_done(tx_done),
    .rx_bv(rx_bv), .rx_byte(rx_byte),
    .rx_frm_v(rx_frm_v), .rx_crc_ok(rx_crc_ok), .rx_match(rx_match),
    .rx_len(rx_len)
);

// selftest FSM ----------------------------------------------------------------
localparam [2:0] M_IDLE = 3'd0, M_ISSUE = 3'd1, M_RUN = 3'd2,
                 M_LEN  = 3'd3, M_ST    = 3'd4, M_NEXT = 3'd5;

reg [2:0]  ms;
reg        running;
reg [31:0] dg;
reg        dg_v;
reg [7:0]  dg_b;
reg [10:0] c_len;
reg        c_ok, c_match;

wire [7:0] status_b = {5'b00000, c_match,
                       ((c_len >= 11'd64) && (c_len <= 11'd1518)), c_ok};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done <= 1'b0; pass <= 1'b0; digest <= 32'd0; cycles <= 16'd0;
        ms <= M_IDLE; fidx <= 2'd0; running <= 1'b0;
        tx_start <= 1'b0; dg <= 32'h811C9DC5; dg_v <= 1'b0; dg_b <= 8'd0;
        c_len <= 11'd0; c_ok <= 1'b0; c_match <= 1'b0;
    end else if (clk_en) begin
        dg_v     <= 1'b0;
        tx_start <= 1'b0;
        if (running && !done) cycles <= cycles + 16'd1;
        case (ms)
            M_IDLE: if (start) begin
                running <= 1'b1;
                done    <= 1'b0;
                dg      <= 32'h811C9DC5;
                cycles  <= 16'd0;
                fidx    <= 2'd0;
                ms      <= M_ISSUE;
            end
            M_ISSUE: begin
                tx_start <= 1'b1;
                ms       <= M_RUN;
            end
            M_RUN: begin
                if (rx_bv) begin
                    dg   <= fnv(dg, rx_byte);
                    dg_b <= rx_byte;
                    dg_v <= 1'b1;
                end
                if (rx_frm_v) begin
                    c_len   <= rx_len;
                    c_ok    <= rx_crc_ok;
                    c_match <= rx_match;
                    ms      <= M_LEN;
                end
            end
            M_LEN: begin
                dg   <= fnv(dg, c_len[7:0]);
                dg_b <= c_len[7:0];
                dg_v <= 1'b1;
                ms   <= M_ST;
            end
            M_ST: begin
                dg   <= fnv(dg, status_b);
                dg_b <= status_b;
                dg_v <= 1'b1;
                ms   <= M_NEXT;
            end
            M_NEXT: begin
                if (fidx == 2'd3) begin
                    digest <= dg;
                    pass   <= (dg === EXP);
                    done   <= 1'b1;
                    ms     <= M_IDLE;
                end else if (!tx_busy) begin   // wait out the IFG
                    fidx <= fidx + 2'd1;
                    ms   <= M_ISSUE;
                end
            end
            default: ms <= M_IDLE;
        endcase
    end
end

endmodule
