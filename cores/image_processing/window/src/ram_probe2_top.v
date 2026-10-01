// ============================================================================
// ram_probe2_top -- BSRAM probe v4: DIRECT DPX9B instantiation replicating
// the exact netlist pattern apycula produces for cnn_systolic_20k's
// board-validated line buffers:
//   DPX9B BIT_WIDTH_0/1 = 18, RESET_MODE=ASYNC
//   ADA = {waddr[9:0], 2'b00, 2'b11}   (be = const 11 -> BEHB/BELB ENABLE)
//   ADB = {raddr[9:0], 4'b0000}
//   DIA = 18-bit data, DOB[8:0] = read data
//   port A: WREA=we CEA=1 ; port B: WREB=0 CEB=re
// Writes 0..127, reads back, streams over uart_tx/dbg_uart(A11).
// ============================================================================
module ram_probe2_top #(
    parameter DEPTH = 128,
    parameter AW    = (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
    input  wire clk,
    output wire uart_tx,
    output wire dbg_uart
);
reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12];
always @(posedge clk) if (!rst_n) reset_count <= reset_count + 13'd1;

reg [AW-1:0] wa = 0;
reg [AW-1:0] ra = 0;
reg         we = 1'b0;
wire [17:0] do_w;
wire [8:0]  q9 = do_w[8:0];

// addrbe(BIT_WIDTH=18): phys = {word_idx[9:0], 2'b00, be[1:0]}
wire [13:0] ada = {wa, 4'b0011};
wire [13:0] adb = {ra, 4'b0000};
wire [17:0] dia = {10'b0, wa[7:0]};

DPX9B #(
    .BIT_WIDTH_0(18), .BIT_WIDTH_1(18),
    .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
    .RESET_MODE("ASYNC")
) u_ram (
    .BLKSELA(3'b000), .BLKSELB(3'b000),
    .CLKA(clk), .CEA(1'b1), .WREA(we), .RESETA(1'b0),
    .ADA(ada), .DIA(dia), .DOA(),
    .CLKB(clk), .CEB(1'b1), .WREB(1'b0), .RESETB(1'b0),
    .ADB(adb), .DIB(18'b0), .DOB(do_w),
    .OCEA(1'b0), .OCEB(1'b0)
);
wire [7:0] q = q9[7:0];

// ---------------- FSM ----------------
localparam PH_W = 3'd0, PH_HDR = 3'd1, PH_RD = 3'd2, PH_GAP = 3'd3;
reg [2:0] ph = PH_W;
reg [AW-1:0] sp = 0;
reg hdr = 1'b0;
reg [24:0] gap = 25'd0;
reg [7:0] tx_data;
reg tx_valid;
wire tx_ready, tx_busy;

uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) uart (
    .clk(clk), .rst_n(rst_n),
    .tx_data(tx_data), .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready), .tx_pin(uart_tx), .tx_busy(tx_busy));
assign dbg_uart = uart_tx;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ph <= PH_W; wa <= 0; ra <= 0; sp <= 0; hdr <= 1'b0; we <= 1'b0;
        tx_valid <= 1'b0; tx_data <= 8'd0; gap <= 25'd0;
    end else begin
        case (ph)
            PH_W: begin
                we <= 1'b1;
                if (wa == DEPTH-1) begin we <= 1'b0; ph <= PH_HDR; end
                else wa <= wa + 1'b1;
            end
            PH_HDR: begin
                if (!tx_valid && tx_ready) begin
                    tx_data <= hdr ? 8'h55 : 8'hAA; tx_valid <= 1'b1;
                end else if (tx_valid && tx_busy) begin
                    tx_valid <= 1'b0;
                    if (hdr) begin ph <= PH_RD; ra <= 0; sp <= 0; end
                    hdr <= ~hdr;
                end
            end
            PH_RD: begin
                if (!tx_valid && tx_ready && sp < DEPTH) begin
                    tx_data <= q; tx_valid <= 1'b1;
                    sp <= sp + 1'b1;
                    ra <= sp + 1'b1;
                end else if (tx_valid && tx_busy) tx_valid <= 1'b0;
                if (sp == DEPTH) ph <= PH_GAP;
            end
            default: begin
                tx_valid <= 1'b0;
                if (gap == 25'd13_500_000) begin
                    hdr <= 1'b0; ph <= PH_HDR;
                end
            end
        endcase
        if (ph == PH_GAP) gap <= gap + 25'd1; else gap <= 25'd0;
    end
end
endmodule
