module doa_uart_reporter #(
    parameter CLK_FRE = 27,
    parameter BAUD_RATE = 115200,
    parameter integer HEARTBEAT_CYCLES = CLK_FRE * 500000
) (
    input wire clk,
    input wire rst_n,
    input wire result_valid,
    input wire [3:0] led_index,
    input wire direction_active,
    input wire [31:0] report0,
    input wire [31:0] report1,
    input wire [31:0] report2,
    input wire [31:0] report3,
    input wire [31:0] diag0,
    input wire [31:0] diag1,
    input wire [31:0] diag2,
    input wire [31:0] diag3,
    output wire uart_tx
);

localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_SEND = 3'd1;
localparam [2:0] S_WAIT = 3'd2;

reg [2:0] state;
reg [5:0] byte_index;
reg [191:0] packet;
reg [15:0] frame_counter;
reg tx_valid;
reg [7:0] tx_data;
reg [3:0] packet_flags;
wire tx_ready;
wire tx_busy;

localparam integer HEARTBEAT_CNT_W = (HEARTBEAT_CYCLES <= 1) ? 1 : $clog2(HEARTBEAT_CYCLES);
reg [HEARTBEAT_CNT_W-1:0] heartbeat_count;

wire [7:0] packet_byte = packet[(24 - byte_index) * 8 - 1 -: 8];
wire heartbeat_enabled = (HEARTBEAT_CYCLES > 0);
wire heartbeat_due = heartbeat_enabled && (heartbeat_count == HEARTBEAT_CYCLES - 1);
wire send_result_frame = result_valid;
wire [31:0] mux_report0 = send_result_frame ? report0 : diag0;
wire [31:0] mux_report1 = send_result_frame ? report1 : diag1;
wire [31:0] mux_report2 = send_result_frame ? report2 : diag2;
wire [31:0] mux_report3 = send_result_frame ? report3 : diag3;

uart_tx #(
    .CLK_FRE(CLK_FRE),
    .BAUD_RATE(BAUD_RATE)
) uart_tx_inst (
    .clk(clk),
    .rst_n(rst_n),
    .tx_data(tx_data),
    .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready),
    .tx_pin(uart_tx),
    .tx_busy(tx_busy)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        byte_index <= 6'd0;
        packet <= 192'd0;
        frame_counter <= 16'd0;
        heartbeat_count <= {HEARTBEAT_CNT_W{1'b0}};
        packet_flags <= 4'd0;
        tx_valid <= 1'b0;
        tx_data <= 8'd0;
    end else begin
        if (tx_valid && tx_ready) begin
            tx_valid <= 1'b0;
        end

        if (state == S_IDLE) begin
            if (result_valid || heartbeat_due) begin
                heartbeat_count <= {HEARTBEAT_CNT_W{1'b0}};
            end else if (heartbeat_enabled) begin
                heartbeat_count <= heartbeat_count + 1'b1;
            end
        end else begin
            heartbeat_count <= {HEARTBEAT_CNT_W{1'b0}};
        end

        case (state)
            S_IDLE: begin
                if (result_valid || heartbeat_due) begin
                    packet_flags <= result_valid ? {3'b000, direction_active} : 4'h1;
                    packet <= {
                        8'hAA,
                        8'h55,
                        8'h01,
                        result_valid ? {3'b000, direction_active} : 4'h1,
                        led_index,
                        mux_report0[31:24], mux_report0[23:16], mux_report0[15:8], mux_report0[7:0],
                        mux_report1[31:24], mux_report1[23:16], mux_report1[15:8], mux_report1[7:0],
                        mux_report2[31:24], mux_report2[23:16], mux_report2[15:8], mux_report2[7:0],
                        mux_report3[31:24], mux_report3[23:16], mux_report3[15:8], mux_report3[7:0],
                        frame_counter[15:8], frame_counter[7:0],
                        8'h0D,
                        8'h0A
                    };
                    frame_counter <= frame_counter + 16'd1;
                    byte_index <= 6'd0;
                    state <= S_SEND;
                end
            end
            S_SEND: begin
                if (!tx_valid && tx_ready) begin
                    tx_data <= packet_byte;
                    tx_valid <= 1'b1;
                    state <= S_WAIT;
                end
            end
            S_WAIT: begin
                if (!tx_valid && !tx_busy) begin
                    if (byte_index == 6'd23) begin
                        state <= S_IDLE;
                    end else begin
                        byte_index <= byte_index + 1'b1;
                        state <= S_SEND;
                    end
                end
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
