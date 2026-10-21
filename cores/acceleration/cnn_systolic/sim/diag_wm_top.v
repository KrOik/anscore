// Diagnostic top v2: replicate cnn_selftest unit 3 verbatim (wm_i, wm_nl,
// 8-deep nested fnv fold into wm_dg), capture each beat's wm_w bytes into
// a buffer, then stream buf + final wm_dg over UART repeatedly.
module diag_wm_top (
    input  wire clk,
    output wire uart_tx_pin
);

localparam integer BEATS = 64;
localparam integer TOTAL = BEATS * 8 + 4;

function [31:0] fnv;
    input [31:0] h;
    input [7:0]  b;
    reg [31:0] x;
    begin
        x = h ^ {24'd0, b};
        fnv = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
    end
endfunction

reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12];
always @(posedge clk) if (!rst_n) reset_count <= reset_count + 13'd1;

// --- verbatim copy of cnn_selftest unit 3 ---
reg [5:0]  wm_i = 6'd0;
reg        wm_done = 1'b0;
reg [31:0] wm_dg = 32'h811c9dc5;
wire signed [1:0][3:0][7:0] wm_w;
wire wm_nl = (wm_i[3:0] == 4'd0);

w_manager #(.PE_ROW_NUM(4), .PE_COL_NUM(2), .WEIGHT_WIDTH(8),
            .CYCLE_PERIOD(4), .WEIGHT_FILE("wm_test.mem")) u_wm (
    .clk(clk), .clk_en(1'b1), .new_line_1(wm_nl), .W_out(wm_w)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wm_i <= 6'd0; wm_done <= 1'b0; wm_dg <= 32'h811c9dc5;
    end else if (!wm_done) begin
        if (wm_i < 6'd48) begin
            wm_i <= wm_i + 6'd1;
            wm_dg <= fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(wm_dg,
                    wm_w[0][0]), wm_w[0][1]), wm_w[0][2]), wm_w[0][3]),
                    wm_w[1][0]), wm_w[1][1]), wm_w[1][2]), wm_w[1][3]);
        end else begin
            wm_done <= 1'b1;
        end
    end
end
// --- end verbatim copy ---

// capture raw bytes for the first 64 wm_i beats
reg [7:0] cbuf [0:TOTAL-1];
reg [6:0] cap_i = 7'd0;
integer bi;
always @(posedge clk) begin
    if (rst_n && cap_i < BEATS) begin
        for (bi = 0; bi < 4; bi = bi + 1) begin
            cbuf[cap_i*8 + bi]     <= wm_w[0][bi];
            cbuf[cap_i*8 + 4 + bi] <= wm_w[1][bi];
        end
        cap_i <= cap_i + 7'd1;
    end else if (rst_n && cap_i == BEATS) begin
        cbuf[512] <= wm_dg[7:0];
        cbuf[513] <= wm_dg[15:8];
        cbuf[514] <= wm_dg[23:16];
        cbuf[515] <= wm_dg[31:24];
        cap_i <= cap_i + 7'd1;
    end
end

reg [9:0]  tx_idx = 10'd0;
reg [7:0]  tx_data = 8'd0;
reg        tx_valid = 1'b0;
reg [1:0]  tx_state = 2'd0;
reg [24:0] gap = 25'd0;
wire       tx_ready, tx_busy;

uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) uart (
    .clk(clk), .rst_n(rst_n), .tx_data(tx_data),
    .tx_data_valid(tx_valid), .tx_data_ready(tx_ready),
    .tx_pin(uart_tx_pin), .tx_busy(tx_busy)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_idx <= 10'd0; tx_data <= 8'd0; tx_valid <= 1'b0;
        tx_state <= 2'd0; gap <= 25'd0;
    end else begin
        case (tx_state)
            2'd0: begin
                tx_valid <= 1'b0;
                if (cap_i <= BEATS) begin
                end else if (gap != 0) begin
                    gap <= gap - 25'd1;
                end else begin
                    tx_state <= 2'd1;
                end
            end
            2'd1: begin
                if (tx_ready) begin
                    tx_data <= cbuf[tx_idx];
                    tx_valid <= 1'b1;
                    tx_state <= 2'd2;
                end
            end
            2'd2: begin
                if (tx_busy) begin
                    tx_valid <= 1'b0;
                    tx_state <= 2'd3;
                end
            end
            2'd3: begin
                if (tx_ready) begin
                    if (tx_idx == TOTAL - 1) begin
                        tx_idx <= 10'd0;
                        tx_state <= 2'd0;
                        gap <= 25'd13_500_000;
                    end else begin
                        tx_idx <= tx_idx + 10'd1;
                        tx_state <= 2'd1;
                    end
                end
            end
        endcase
    end
end

endmodule
