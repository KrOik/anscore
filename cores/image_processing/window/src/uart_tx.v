module uart_tx #(
    parameter integer CLK_FRE = 27,
    parameter integer BAUD_RATE = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] tx_data,
    input  wire       tx_data_valid,
    output wire       tx_data_ready,
    output wire       tx_pin,
    output wire       tx_busy
);

localparam integer CYCLE = CLK_FRE * 1000000 / BAUD_RATE;
localparam integer CNT_W = (CYCLE <= 1) ? 1 : $clog2(CYCLE);
localparam [CNT_W-1:0] CYCLE_MAX = CYCLE - 1;

localparam [2:0] S_IDLE      = 3'd0;
localparam [2:0] S_START_BIT = 3'd1;
localparam [2:0] S_DATA_BITS = 3'd2;
localparam [2:0] S_STOP_BIT  = 3'd3;

reg [2:0] state;
reg [CNT_W-1:0] cycle_cnt;
reg [2:0] bit_cnt;
reg [7:0] data_latch;
reg tx_reg;

wire bit_tick = (cycle_cnt == CYCLE_MAX);
wire accept = tx_data_valid && (state == S_IDLE);

assign tx_data_ready = (state == S_IDLE);
assign tx_busy = (state != S_IDLE);
assign tx_pin = tx_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        cycle_cnt <= {CNT_W{1'b0}};
        bit_cnt <= 3'd0;
        data_latch <= 8'd0;
        tx_reg <= 1'b1;
    end else begin
        case (state)
            S_IDLE: begin
                cycle_cnt <= {CNT_W{1'b0}};
                bit_cnt <= 3'd0;
                tx_reg <= 1'b1;
                if (accept) begin
                    data_latch <= tx_data;
                    tx_reg <= 1'b0;
                    state <= S_START_BIT;
                end
            end

            S_START_BIT: begin
                if (bit_tick) begin
                    cycle_cnt <= {CNT_W{1'b0}};
                    tx_reg <= data_latch[0];
                    state <= S_DATA_BITS;
                end else begin
                    cycle_cnt <= cycle_cnt + 1'b1;
                end
            end

            S_DATA_BITS: begin
                if (bit_tick) begin
                    cycle_cnt <= {CNT_W{1'b0}};
                    if (bit_cnt == 3'd7) begin
                        tx_reg <= 1'b1;
                        state <= S_STOP_BIT;
                    end else begin
                        bit_cnt <= bit_cnt + 3'd1;
                        tx_reg <= data_latch[bit_cnt + 3'd1];
                    end
                end else begin
                    cycle_cnt <= cycle_cnt + 1'b1;
                end
            end

            S_STOP_BIT: begin
                if (bit_tick) begin
                    cycle_cnt <= {CNT_W{1'b0}};
                    state <= S_IDLE;
                end else begin
                    cycle_cnt <= cycle_cnt + 1'b1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
