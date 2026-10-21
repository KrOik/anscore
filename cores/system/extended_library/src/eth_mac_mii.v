// ============================================================================
// eth_mac_mii -- simplified MII Ethernet MAC (10/100 style, 4-bit datapath).
//
// TX: preamble 7x0x55 + SFD 0xD5, frame body pulled from a byte stream port
//     (dest,src,type,payload), zero pad to 60 bytes, CRC32 FCS append,
//     12-byte IFG. One nibble per clk_en beat on mii_txd (low nibble first).
// RX: preamble/SFD detect, nibble->byte assembly, CRC32 residue check
//     (== 32'hDEBB20E3 for a good frame), destination MAC filter
//     (MAC_ADDR or broadcast FF:FF:FF:FF:FF:FF), per-byte rx_bv stream.
//
// CRC32: IEEE 802.3 reflected poly 0xEDB88320, init FFFFFFFF. FCS bytes are
// transmitted ~crc[7:0] .. ~crc[31:24] (LSB byte first) so that a good frame
// leaves the constant residue 0xDEBB20E3.
//
// loopback=1 connects the internal TX stream to the RX path (selftest).
// All registers clk_en gated.
// ============================================================================
module eth_mac_mii #(
    parameter [47:0] MAC_ADDR = 48'h021122334455
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    // MII
    output wire        mii_tx_en,
    output wire [3:0]  mii_txd,
    input  wire        mii_rx_dv,
    input  wire [3:0]  mii_rxd,
    input  wire        loopback,
    // TX frame source: present tx_byte combinationally for index tx_bidx
    input  wire        tx_start,
    input  wire [10:0] tx_len,      // frame body length (dest..payload), >=14
    output wire [10:0] tx_bidx,
    input  wire [7:0]  tx_byte,
    output reg         tx_busy,
    output reg         tx_done,     // 1 clk_en pulse after IFG
    // RX output stream
    output reg         rx_bv,       // received byte valid (post-SFD incl FCS)
    output reg  [7:0]  rx_byte,
    output reg         rx_frm_v,    // end-of-frame pulse, results valid
    output reg         rx_crc_ok,
    output reg         rx_match,    // destination MAC matched
    output reg  [10:0] rx_len       // post-SFD byte count incl FCS
);

// ---------------------------------------------------------------------------
// CRC32 helpers (IEEE 802.3, reflected)
// ---------------------------------------------------------------------------
function [31:0] crc32_nib;
    input [31:0] c;
    input [3:0]  n;
    reg   [31:0] t;
    integer k;
    begin
        t = c;
        for (k = 0; k < 4; k = k + 1)
            t = {1'b0, t[31:1]} ^ ((t[0] ^ n[k]) ? 32'hEDB88320 : 32'd0);
        crc32_nib = t;
    end
endfunction

// ===========================================================================
// TX engine
// ===========================================================================
localparam [2:0] T_IDLE = 3'd0, T_PRE = 3'd1, T_SFD = 3'd2,
                 T_DAT  = 3'd3, T_FCS = 3'd4, T_IFG = 3'd5;

reg [2:0]  ts;
reg [4:0]  ncnt;                    // nibble counter for pre/ifg
reg [10:0] bcnt;                    // byte index within data/fcs
reg        nhi;                     // 0 = low nibble on the wire
reg [7:0]  tbyte;
reg [31:0] tcrc;
reg [10:0] tlen;
reg [10:0] tpay;                    // emitted body bytes = max(tlen,60)
reg [31:0] fcs_r;
reg        txen_r;
reg [3:0]  txd_r;

assign mii_tx_en = txen_r;
assign mii_txd   = txd_r;
assign tx_bidx   = bcnt;

wire [7:0] fcs_b = (bcnt == 11'd0) ? fcs_r[7:0]   :
                   (bcnt == 11'd1) ? fcs_r[15:8]  :
                   (bcnt == 11'd2) ? fcs_r[23:16] : fcs_r[31:24];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ts <= T_IDLE; ncnt <= 5'd0; bcnt <= 11'd0; nhi <= 1'b0;
        tbyte <= 8'd0; tcrc <= 32'hFFFFFFFF; tlen <= 11'd0; tpay <= 11'd0;
        fcs_r <= 32'd0; txen_r <= 1'b0; txd_r <= 4'd0;
        tx_busy <= 1'b0; tx_done <= 1'b0;
    end else if (clk_en) begin
        tx_done <= 1'b0;
        case (ts)
            T_IDLE: begin
                txen_r <= 1'b0;
                if (tx_start) begin
                    tx_busy <= 1'b1;
                    tlen <= tx_len;
                    tpay <= (tx_len < 11'd60) ? 11'd60 : tx_len;
                    tcrc <= 32'hFFFFFFFF;
                    ncnt <= 5'd0;
                    ts   <= T_PRE;
                end
            end
            T_PRE: begin                       // 7 bytes 0x55 -> 14 nibbles 5
                txen_r <= 1'b1;
                txd_r  <= 4'h5;
                if (ncnt == 5'd13) begin
                    ncnt <= 5'd0;
                    ts   <= T_SFD;
                end else ncnt <= ncnt + 5'd1;
            end
            T_SFD: begin                       // 0xD5 -> nibbles 5 then D
                txd_r <= nhi ? 4'hD : 4'h5;
                if (nhi) begin
                    nhi  <= 1'b0;
                    bcnt <= 11'd0;
                    ts   <= T_DAT;
                end else nhi <= 1'b1;
            end
            T_DAT: begin
                if (!nhi)
                    tbyte <= (bcnt < tlen) ? tx_byte : 8'h00;
                txd_r <= nhi ? tbyte[7:4] :
                               ((bcnt < tlen) ? tx_byte[3:0] : 4'h0);
                tcrc  <= crc32_nib(tcrc,
                          nhi ? tbyte[7:4] :
                                ((bcnt < tlen) ? tx_byte[3:0] : 4'h0));
                if (nhi) begin
                    nhi <= 1'b0;
                    if (bcnt == tpay - 11'd1) begin
                        bcnt  <= 11'd0;
                        fcs_r <= ~crc32_nib(tcrc, tbyte[7:4]);
                        ts    <= T_FCS;
                    end else bcnt <= bcnt + 11'd1;
                end else nhi <= 1'b1;
            end
            T_FCS: begin
                txd_r <= nhi ? fcs_b[7:4] : fcs_b[3:0];
                if (nhi) begin
                    nhi <= 1'b0;
                    if (bcnt == 11'd3) begin
                        ncnt <= 5'd0;
                        ts   <= T_IFG;
                    end else bcnt <= bcnt + 11'd1;
                end else nhi <= 1'b1;
            end
            T_IFG: begin                       // 12 idle byte times
                txen_r <= 1'b0;
                if (ncnt == 5'd23) begin
                    tx_busy <= 1'b0;
                    tx_done <= 1'b1;
                    ts      <= T_IDLE;
                end else ncnt <= ncnt + 5'd1;
            end
            default: ts <= T_IDLE;
        endcase
    end
end

// ===========================================================================
// RX engine
// ===========================================================================
wire [3:0] rxd_w = loopback ? mii_txd  : mii_rxd;
wire       rdv_w = loopback ? mii_tx_en : mii_rx_dv;

localparam [1:0] R_IDLE = 2'd0, R_PRE = 2'd1, R_DAT = 2'd2;

reg [1:0]  rs;
reg        rdv_d;
reg        prev5;                   // previous nibble was 0x5
reg        nib2;                    // 1 = expecting high nibble
reg [3:0]  nib_r;
reg [31:0] rcrc;
reg [10:0] rcnt;
reg [47:0] rdest;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rs <= R_IDLE; rdv_d <= 1'b0; prev5 <= 1'b0; nib2 <= 1'b0;
        nib_r <= 4'd0; rcrc <= 32'hFFFFFFFF; rcnt <= 11'd0; rdest <= 48'd0;
        rx_bv <= 1'b0; rx_byte <= 8'd0; rx_frm_v <= 1'b0;
        rx_crc_ok <= 1'b0; rx_match <= 1'b0; rx_len <= 11'd0;
    end else if (clk_en) begin
        rx_bv    <= 1'b0;
        rx_frm_v <= 1'b0;
        rdv_d    <= rdv_w;
        case (rs)
            R_IDLE: begin
                if (rdv_w) begin
                    rs    <= R_PRE;
                    prev5 <= 1'b0;
                end
            end
            R_PRE: begin                       // preamble nibbles then SFD
                if (!rdv_w) begin
                    rs <= R_IDLE;              // false start
                end else if (rxd_w == 4'hD && prev5) begin
                    rs    <= R_DAT;            // SFD complete
                    nib2  <= 1'b0;
                    rcrc  <= 32'hFFFFFFFF;
                    rcnt  <= 11'd0;
                    rdest <= 48'd0;
                end else prev5 <= (rxd_w == 4'h5);
            end
            R_DAT: begin
                if (!rdv_w) begin              // frame ended
                    rx_len    <= rcnt;
                    rx_crc_ok <= (rcrc == 32'hDEBB20E3);
                    rx_match  <= (rdest == MAC_ADDR) ||
                                 (rdest == 48'hFFFFFFFFFFFF);
                    rx_frm_v  <= 1'b1;
                    rs        <= R_IDLE;
                end else begin
                    rcrc <= crc32_nib(rcrc, rxd_w);
                    if (!nib2) begin
                        nib_r <= rxd_w;
                        nib2  <= 1'b1;
                    end else begin
                        rx_bv   <= 1'b1;
                        rx_byte <= {rxd_w, nib_r};
                        if (rcnt < 11'd6) rdest <= {rdest[39:0], {rxd_w, nib_r}};
                        rcnt <= rcnt + 11'd1;
                        nib2 <= 1'b0;
                    end
                end
            end
            default: rs <= R_IDLE;
        endcase
    end
end

endmodule
