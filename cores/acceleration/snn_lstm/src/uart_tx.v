`timescale 1ns / 1ps
// 8N1 UART transmitter, parameterised clock-per-bit (50 MHz / 115200 = 434).
// Frame = start(0) + 8 data LSB-first + stop(1); shift holds {stop, data[7:0]}
// so the value presented after each bit period is already the next line level.
module uart_tx #(
    parameter CLKS_PER_BIT = 434,
    parameter CB_W         = 10
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data,
    output reg        busy,
    output reg        tx
);
    reg [CB_W-1:0] cnt;
    reg [3:0]      bitidx;
    reg [8:0]      shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; tx <= 1'b1; cnt <= {CB_W{1'b0}};
            bitidx <= 4'd0; shift <= 9'h1FF;
        end else if (!busy && start) begin
            busy   <= 1'b1;
            tx     <= 1'b0;                       // start bit
            shift  <= {1'b1, data};               // stop above the 8 data bits
            cnt    <= CLKS_PER_BIT - 1;
            bitidx <= 4'd0;
        end else if (busy) begin
            if (cnt != 0) begin
                cnt <= cnt - 1'b1;
            end else begin
                cnt   <= CLKS_PER_BIT - 1;
                tx    <= shift[0];                // d0..d7, then stop
                shift <= {1'b1, shift[8:1]};
                // bitidx 0..7 data, 8 presents the stop, 9 ends the frame so the
                // stop bit owns a full bit period before the next byte may start.
                if (bitidx == 4'd9) begin
                    busy   <= 1'b0;
                    tx     <= 1'b1;
                    bitidx <= 4'd0;
                end else begin
                    bitidx <= bitidx + 1'b1;
                end
            end
        end
    end
endmodule
