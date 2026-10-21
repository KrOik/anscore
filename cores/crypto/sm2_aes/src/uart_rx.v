module uart_rx #(
    parameter CLK_HZ = 27000000,
    parameter BAUD   = 3000000
) (
    input  wire clk,
    input  wire rst,
    input  wire rx,
    output reg  data_valid,
    output reg  [7:0] data
);

localparam CLKS_PER_BIT = CLK_HZ / BAUD;
localparam HALF_BIT     = CLKS_PER_BIT / 2;

localparam ST_IDLE  = 3'd0;
localparam ST_START = 3'd1;
localparam ST_DATA  = 3'd2;
localparam ST_STOP  = 3'd3;

reg [2:0] state;
reg [7:0] clk_cnt;
reg [2:0] bit_idx;
reg [7:0] shreg;
reg rx_meta;
reg rx_sync;

always @(posedge clk) begin
    rx_meta <= rx;
    rx_sync <= rx_meta;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= ST_IDLE;
        clk_cnt <= 8'd0;
        bit_idx <= 3'd0;
        shreg <= 8'd0;
        data <= 8'd0;
        data_valid <= 1'b0;
    end else begin
        data_valid <= 1'b0;
        case (state)
            ST_IDLE: begin
                clk_cnt <= 8'd0;
                bit_idx <= 3'd0;
                if (!rx_sync)
                    state <= ST_START;
            end

            ST_START: begin
                if (clk_cnt == HALF_BIT - 1) begin
                    clk_cnt <= 8'd0;
                    state <= rx_sync ? ST_IDLE : ST_DATA;
                end else begin
                    clk_cnt <= clk_cnt + 8'd1;
                end
            end

            ST_DATA: begin
                if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 8'd0;
                    shreg[bit_idx] <= rx_sync;
                    if (bit_idx == 3'd7)
                        state <= ST_STOP;
                    else
                        bit_idx <= bit_idx + 3'd1;
                end else begin
                    clk_cnt <= clk_cnt + 8'd1;
                end
            end

            ST_STOP: begin
                if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 8'd0;
                    data <= shreg;
                    data_valid <= rx_sync;
                    state <= ST_IDLE;
                end else begin
                    clk_cnt <= clk_cnt + 8'd1;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
