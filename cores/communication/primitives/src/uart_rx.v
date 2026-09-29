// UART receiver (default 115200 baud @27 MHz) with 3-sample oversampling
// around each bit center + majority vote. Detects false start bits and
// raises framing_err when the stop bit is not high.
//
// clk_en protocol: every internal register is gated by clk_en; tie 1'b1 for
// a free-running receiver.
//
// rx_valid is a held level: it stays high until rx_ack pulses, so a slow
// consumer can observe the held byte. framing_err is valid while rx_valid is.
// Acknowledge before the next frame completes for lossless streaming. If
// the consumer overruns this one-byte holding register, the older unread
// byte is retained and the newly completed frame is discarded.
module uart_rx #(
    parameter integer CLK_FRE   = 27,
    parameter integer BAUD_RATE = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clk_en,
    input  wire       rx_pin,
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    input  wire       rx_ack,
    output reg        framing_err
);

localparam integer CYCLE = CLK_FRE * 1000000 / BAUD_RATE;
localparam integer CNT_W = (CYCLE <= 3) ? 2 : $clog2(CYCLE);
localparam [CNT_W-1:0] CYC_MAX = CYCLE - 1;
// sample points inside a bit period (center +/- eighth bit)
localparam [CNT_W-1:0] S0 = CYCLE / 2 - CYCLE / 8;
localparam [CNT_W-1:0] S1 = CYCLE / 2;
localparam [CNT_W-1:0] S2 = CYCLE / 2 + CYCLE / 8;

localparam [2:0] ST_IDLE  = 3'd0;
localparam [2:0] ST_START = 3'd1;
localparam [2:0] ST_DATA  = 3'd2;
localparam [2:0] ST_STOP  = 3'd3;

reg [2:0]       state;
reg [CNT_W-1:0] cnt;
reg [1:0]       smp;       // 3-sample accumulator
reg [2:0]       bit_cnt;
reg [7:0]       shift;
reg             rx_meta = 1'b1, rx_sync = 1'b1;  // init==arst for DFFLEGALIZE

wire maj = (smp >= 2'd2);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= ST_IDLE;
        cnt         <= {CNT_W{1'b0}};
        smp         <= 2'd0;
        bit_cnt     <= 3'd0;
        shift       <= 8'd0;
        rx_data     <= 8'd0;
        rx_valid    <= 1'b0;
        framing_err <= 1'b0;
        rx_meta     <= 1'b1;
        rx_sync     <= 1'b1;
    end else if (clk_en) begin
        rx_meta <= rx_pin;
        rx_sync <= rx_meta;
        // Output consumption must not stall start-bit detection.
        if (rx_ack) rx_valid <= 1'b0;

        if (state == ST_START || state == ST_DATA || state == ST_STOP) begin
            if (cnt == S0 || cnt == S1 || cnt == S2)
                smp <= smp + {1'b0, rx_sync};
        end

        case (state)
            ST_IDLE: begin
                cnt <= {CNT_W{1'b0}};
                smp <= 2'd0;
                if (!rx_sync) begin
                    state <= ST_START;
                    cnt   <= {CNT_W{1'b0}};
                    smp   <= 2'd0;
                end
            end

            ST_START: begin
                if (cnt == CYC_MAX) begin
                    cnt <= {CNT_W{1'b0}};
                    smp <= 2'd0;
                    if (maj) begin
                        state <= ST_IDLE;      // false start bit
                    end else begin
                        state   <= ST_DATA;
                        bit_cnt <= 3'd0;
                    end
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end

            ST_DATA: begin
                if (cnt == CYC_MAX) begin
                    cnt   <= {CNT_W{1'b0}};
                    smp   <= 2'd0;
                    shift <= {maj, shift[7:1]};
                    if (bit_cnt == 3'd7) begin
                        state <= ST_STOP;
                    end else begin
                        bit_cnt <= bit_cnt + 3'd1;
                    end
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end

            ST_STOP: begin
                // All three stop samples are available now. Re-arm before
                // the next start edge, avoiding accumulated synchronizer
                // delay across contiguous frames with one stop bit.
                if (cnt == S2 + 1'b1) begin
                    cnt         <= {CNT_W{1'b0}};
                    smp         <= 2'd0;
                    if (!rx_valid || rx_ack) begin
                        rx_data     <= shift;
                        framing_err <= ~maj;
                        rx_valid    <= 1'b1;
                    end
                    state       <= ST_IDLE;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
