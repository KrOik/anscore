module uart_tx #(
    parameter CLK_FRE = 27,
    parameter BAUD_RATE = 115200
) (
    input wire clk,
    input wire rst_n,
    input wire [7:0] tx_data,
    input wire tx_data_valid,
    output wire tx_data_ready,
    output wire tx_pin,
    output wire tx_busy
);

localparam integer CYCLE = CLK_FRE * 1000000 / BAUD_RATE;
localparam integer CNT_W = (CYCLE <= 1) ? 1 : $clog2(CYCLE);
localparam [CNT_W-1:0] CYCLE_MAX = CYCLE - 1;

localparam [2:0] S_IDLE = 3'd1;
localparam [2:0] S_START = 3'd2;
localparam [2:0] S_SEND_BYTE = 3'd3;
localparam [2:0] S_STOP = 3'd4;

reg [CNT_W-1:0] cycle_cnt;
reg [2:0] state;
reg [2:0] next_state;
reg [2:0] bit_cnt;
reg [7:0] tx_data_latch;
reg tx_reg;

wire bit_tick = (cycle_cnt == CYCLE_MAX);
wire accept = (state == S_IDLE) && tx_data_valid;

assign tx_data_ready = (state == S_IDLE);
assign tx_busy = (state != S_IDLE);
assign tx_pin = tx_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
    end else begin
        state <= next_state;
    end
end

always @(*) begin
    case (state)
        S_IDLE: begin
            if (tx_data_valid) begin
                next_state = S_START;
            end else begin
                next_state = S_IDLE;
            end
        end
        S_START: begin
            if (bit_tick) begin
                next_state = S_SEND_BYTE;
            end else begin
                next_state = S_START;
            end
        end
        S_SEND_BYTE: begin
            if (bit_tick && bit_cnt == 3'd7) begin
                next_state = S_STOP;
            end else begin
                next_state = S_SEND_BYTE;
            end
        end
        S_STOP: begin
            if (bit_tick) begin
                next_state = S_IDLE;
            end else begin
                next_state = S_STOP;
            end
        end
        default: next_state = S_IDLE;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_data_latch <= 8'd0;
    end else if (accept) begin
        tx_data_latch <= tx_data;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bit_cnt <= 3'd0;
    end else if (state == S_SEND_BYTE) begin
        if (bit_tick) begin
            bit_cnt <= bit_cnt + 3'd1;
        end
    end else begin
        bit_cnt <= 3'd0;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cycle_cnt <= {CNT_W{1'b0}};
    end else if (state == S_IDLE) begin
        cycle_cnt <= {CNT_W{1'b0}};
    end else if (bit_tick) begin
        cycle_cnt <= {CNT_W{1'b0}};
    end else begin
        cycle_cnt <= cycle_cnt + 1'b1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_reg <= 1'b1;
    end else begin
        case (state)
            S_IDLE, S_STOP: tx_reg <= 1'b1;
            S_START: tx_reg <= 1'b0;
            S_SEND_BYTE: tx_reg <= tx_data_latch[bit_cnt];
            default: tx_reg <= 1'b1;
        endcase
    end
end

endmodule
