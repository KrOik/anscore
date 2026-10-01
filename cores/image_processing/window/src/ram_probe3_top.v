// ============================================================================
// ram_probe3_top -- DOB read-latency probe for direct DPX9B instantiation.
// Phase 1 (raw clk): write mem[0]=0x0A, mem[1]=0x1A; then ra: 0->1 and
//   sample dob at +1,+2,+4 clk -> reveals comb vs registered DOB.
// Phase 2 (clk_en strobe): sequential write/read of 16 entries through the
//   gated CEA/CEB + external q register (exact line_buf_ram usage).
// Streams: AA 55 s1 s2 s3 | AA 55 r0..r15  repeating.
// ============================================================================
module ram_probe3_top (
    input  wire clk,
    output wire uart_tx,
    output wire dbg_uart
);
reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12];
always @(posedge clk) if (!rst_n) reset_count <= reset_count + 13'd1;

reg [2:0] ce_div = 0;
wire clk_en = (ce_div == 3'd7);
always @(posedge clk) ce_div <= ce_div + 3'd1;

reg [3:0] wa = 0, ra = 0, ra1 = 0;
reg we = 1'b0;
reg lat_done = 0;
wire [17:0] dob;
wire [3:0] ra_mux = lat_done ? ra : ra1;
wire [13:0] ada = {6'b0, wa, 2'b00, 2'b11};
wire [13:0] adb = {6'b0, ra_mux, 4'b0000};
wire [17:0] dia = {10'b0, wa[3:0], 4'b1010};   // data = (addr<<4)|A

DPX9B #(
    .BIT_WIDTH_0(18), .BIT_WIDTH_1(18),
    .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
    .RESET_MODE("ASYNC")
) u_ram (
    .BLKSELA(3'b000), .BLKSELB(3'b000),
    .CLKA(clk), .CEA(clk_en), .WREA(we), .RESETA(1'b0),
    .ADA(ada), .DIA(dia), .DOA(),
    .CLKB(clk), .CEB(clk_en), .WREB(1'b0), .RESETB(1'b0),
    .ADB(adb), .DIB(18'b0), .DOB(dob),
    .OCEA(1'b0), .OCEB(1'b0)
);

reg [8:0] q_ext;
always @(posedge clk) if (clk_en) q_ext <= dob[8:0];

// ---------------- Phase 1: raw-clk DOB latency ----------------
// lat_cnt timeline (raw clk):
//   0..3: ra=0 settle   4: ra<=1   5: s1<=dob   6: s2<=dob   8: s3<=dob
reg [3:0] lat_cnt = 0;
reg wr_done = 0;
reg [7:0] s1 = 0, s2 = 0, s3 = 0;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin lat_cnt <= 0; lat_done <= 0; ra1 <= 0; s1 <= 0; s2 <= 0; s3 <= 0; end
    else if (!lat_done && wr_done) begin
        lat_cnt <= lat_cnt + 1;
        if (lat_cnt == 4) ra1 <= 1;
        if (lat_cnt == 5) s1 <= dob[7:0];
        if (lat_cnt == 6) s2 <= dob[7:0];
        if (lat_cnt == 8) begin s3 <= dob[7:0]; lat_done <= 1; end
    end
end

// ---------------- Phase 2: gated sequential read stream ----------------
localparam S_W = 3'd0, S_HDR = 3'd1, S_LAT = 3'd2, S_RD = 3'd3, S_GAP = 3'd4;
reg [2:0] st = S_W;
reg [4:0] idx = 0;
reg [1:0] hcnt = 0;
reg [23:0] gap = 0;
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
        st <= S_W; wa <= 0; we <= 0; idx <= 0; hcnt <= 0; gap <= 0; wr_done <= 0;
        tx_valid <= 0; tx_data <= 0;
    end else if (clk_en) begin
        case (st)
            S_W: begin                                    // write mem[i]=i<<4|A
                we <= 1;
                if (idx == 15) begin we <= 0; idx <= 0; wr_done <= 1; st <= S_HDR; end
                else begin idx <= idx + 1; wa <= idx + 1; end
            end
            S_HDR: begin                                  // send AA 55
                if (!tx_valid && tx_ready) begin
                    tx_valid <= 1; tx_data <= hcnt ? 8'h55 : 8'hAA;
                end else if (tx_valid && tx_busy) begin
                    tx_valid <= 0;
                    if (hcnt == 1) begin hcnt <= 0; st <= S_LAT; idx <= 0; end
                    else hcnt <= hcnt + 1;
                end
            end
            S_LAT: begin                                  // send s1 s2 s3
                if (!tx_valid && tx_ready) begin
                    tx_valid <= 1;
                    tx_data <= (idx == 0) ? s1 : (idx == 1) ? s2 : s3;
                end else if (tx_valid && tx_busy) begin
                    tx_valid <= 0;
                    if (idx == 2) begin idx <= 0; ra <= 0; st <= S_RD; end
                    else idx <= idx + 1;
                end
            end
            S_RD: begin                                   // stream q_ext r0..r15
                if (!tx_valid && tx_ready && idx < 16) begin
                    tx_data <= q_ext[7:0]; tx_valid <= 1;
                    idx <= idx + 1; ra <= idx + 1;
                end else if (tx_valid && tx_busy) tx_valid <= 0;
                if (idx == 16) st <= S_GAP;
            end
            default: begin
                tx_valid <= 0;
                if (gap == 24'd8_000_000) st <= S_HDR;
            end
        endcase
        if (st == S_GAP) gap <= gap + 1; else gap <= 0;
    end
end
endmodule
