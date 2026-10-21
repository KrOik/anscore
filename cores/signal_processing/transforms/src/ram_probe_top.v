// ============================================================================
// ram_probe_top -- standalone sig_sdp_ram probe for board debug.
// Writes a full-18-bit pattern (both 9-bit lanes exercised):
//   data[i] = {i[5:0], 2'b10, i[5:0], 4'b1010}  (high lane != low lane)
// then loops: read addr i, stream 4 UART bytes [addr][17:16|hi6][15:8][7:0].
// uart -> A11 (LA ch D0).  Isolates per-lane write/read correctness.
// ============================================================================
module ram_probe_top (
    input  wire clk,
    output wire uart_tx,
    output wire dbg_uart
);

localparam DEPTH = 64;

localparam [2:0] P_WR   = 3'd0;
localparam [2:0] P_RDQ  = 3'd1;
localparam [2:0] P_RDD  = 3'd2;
localparam [2:0] P_SEND = 3'd3;
localparam [2:0] P_GAP  = 3'd4;

reg [2:0]  st;
reg [6:0]  cnt;
reg [5:0]  rd_i;
reg [1:0]  byte_i;
reg        we;
reg [5:0]  waddr;
reg [17:0] wdata;
reg        re;
reg [5:0]  raddr;
wire [17:0] q;

reg        tx_valid;
wire       tx_ready, tx_busy;
wire [7:0] tx_data;

sig_sdp_ram #(.WIDTH(18), .DEPTH(64)) ram (
    .clk(clk), .clk_en(1'b1),
    .we(we), .waddr(waddr), .wdata(wdata),
    .re(re), .raddr(raddr), .q(q)
);

// expected pattern: {i[5:0], 2'b10, i[5:0], 4'b1010}
//   = [17:12]=i  [11:10]=2'b10  [9:4]=i  [3:0]=4'hA
wire [17:0] pat = {cnt[5:0], 2'b10, cnt[5:0], 4'b1010};

assign tx_data = (byte_i == 2'd0) ? {2'b00, rd_i} :
                 (byte_i == 2'd1) ? {q[17:16], q[15:10]} :
                 (byte_i == 2'd2) ? q[15:8] : q[7:0];

uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) uart (
    .clk(clk), .rst_n(1'b1),
    .tx_data(tx_data), .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready), .tx_pin(dbg_uart), .tx_busy(tx_busy)
);
assign uart_tx = dbg_uart;

always @(posedge clk) begin
    case (st)
        P_WR: begin
            we <= 1'b1; re <= 1'b0; tx_valid <= 1'b0;
            waddr <= cnt[5:0]; wdata <= pat;
            if (cnt == DEPTH - 1) begin st <= P_RDQ; cnt <= 7'd0; rd_i <= 6'd0; end
            else cnt <= cnt + 7'd1;
        end
        P_RDQ: begin
            we <= 1'b0; re <= 1'b1; raddr <= rd_i; tx_valid <= 1'b0;
            byte_i <= 2'd0;
            st <= P_RDD;
        end
        P_RDD: begin
            re <= 1'b0;
            st <= P_SEND;
        end
        P_SEND: begin
            if (tx_ready && !tx_busy) begin
                tx_valid <= 1'b1;
                if (byte_i == 2'd3) begin
                    byte_i <= 2'd0;
                    rd_i <= (rd_i == DEPTH - 1) ? 6'd0 : rd_i + 6'd1;
                    st <= P_GAP;
                end else begin
                    byte_i <= byte_i + 2'd1;
                    st <= P_GAP;
                end
            end else begin
                tx_valid <= 1'b0;
            end
        end
        P_GAP: begin
            tx_valid <= 1'b0;
            if (byte_i == 2'd0) st <= P_RDQ;
            else                st <= P_SEND;
        end
        default: st <= P_WR;
    endcase
end

initial begin
    st = P_WR; cnt = 0; rd_i = 0; byte_i = 0;
    we = 0; waddr = 0; wdata = 0; re = 0; raddr = 0;
    tx_valid = 0;
end

endmodule
