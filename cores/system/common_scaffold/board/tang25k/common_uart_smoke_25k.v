`default_nettype none

// Isolated Tang Primer 25K board smoke harness for common_ip_scaffold UART.
//
// At power-up the UART TX output is looped back into the UART RX input.  The
// controller transmits "CIP25K", reads each byte from the UART RX mailbox,
// and compares it with the transmitted byte.  Only after all six bytes match
// does it send "PASS common_uart\r\n" to the board's USB-UART bridge.  On any
// mismatch, UART error, or receive timeout it sends "FAIL common_uart\r\n".
//
// Board pins (see tang25k.cst): 50 MHz oscillator E2, UART TX C3, debug E8.
// B3 is retained as a normal external UART RX input after the self-test.
module common_uart_smoke_25k #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 115200,
    parameter integer TIMEOUT_CYCLES = 1000000
) (
    input  wire clk,
    input  wire uart_rx_pin,
    output wire uart_tx,
    output wire dbg_uart
);
    localparam [4:0] ST_BOOT             = 5'd0;
    localparam [4:0] ST_PATTERN_TX_ISSUE = 5'd1;
    localparam [4:0] ST_PATTERN_TX_WAIT  = 5'd2;
    localparam [4:0] ST_RX_POLL_ISSUE    = 5'd3;
    localparam [4:0] ST_RX_POLL_WAIT     = 5'd4;
    localparam [4:0] ST_RX_ISSUE         = 5'd5;
    localparam [4:0] ST_RX_WAIT          = 5'd6;
    localparam [4:0] ST_PASS_TX_ISSUE    = 5'd7;
    localparam [4:0] ST_PASS_TX_WAIT     = 5'd8;
    localparam [4:0] ST_PASS_DRAIN_ISSUE = 5'd9;
    localparam [4:0] ST_PASS_DRAIN_WAIT  = 5'd10;
    localparam [4:0] ST_FAIL_START       = 5'd11;
    localparam [4:0] ST_FAIL_TX_ISSUE    = 5'd12;
    localparam [4:0] ST_FAIL_TX_WAIT     = 5'd13;
    localparam [4:0] ST_FAIL_DRAIN_ISSUE = 5'd14;
    localparam [4:0] ST_FAIL_DRAIN_WAIT  = 5'd15;
    localparam [4:0] ST_FAILED           = 5'd16;
    localparam [4:0] ST_DONE             = 5'd17;

    localparam integer PATTERN_LEN = 6;
    localparam integer MESSAGE_LEN = 18;

    // GW5A FPGA power-up register initialization holds the UART in reset for
    // 32768 oscillator clocks, giving the board clock time to settle.
    reg [15:0] por_count = 16'd0;
    always @(posedge clk) begin
        if (!por_count[15])
            por_count <= por_count + 16'd1;
    end
    wire rst_n = por_count[15];

    reg [4:0] state;
    reg loopback_enable;
    reg pass_latched;
    reg fail_latched;
    reg [2:0] pattern_index;
    reg [4:0] message_index;
    reg [31:0] wait_count;
    reg [23:0] fail_blink;

    wire core_tx;
    wire core_rx = loopback_enable ? core_tx : uart_rx_pin;
    wire cmd_valid;
    wire cmd_ready;
    wire cmd_write;
    wire [7:0] cmd_addr;
    wire [31:0] cmd_wdata;
    wire rsp_valid;
    wire rsp_ready;
    wire [31:0] rsp_rdata;
    wire [1:0] rsp_error;

    function [7:0] pattern_byte;
        input [2:0] index;
        begin
            case (index)
                3'd0: pattern_byte = "C";
                3'd1: pattern_byte = "I";
                3'd2: pattern_byte = "P";
                3'd3: pattern_byte = "2";
                3'd4: pattern_byte = "5";
                default: pattern_byte = "K";
            endcase
        end
    endfunction

    function [7:0] result_byte;
        input [4:0] index;
        input is_fail;
        begin
            if (is_fail) begin
                case (index)
                    5'd0:  result_byte = "F";
                    5'd1:  result_byte = "A";
                    5'd2:  result_byte = "I";
                    5'd3:  result_byte = "L";
                    5'd4:  result_byte = " ";
                    5'd5:  result_byte = "c";
                    5'd6:  result_byte = "o";
                    5'd7:  result_byte = "m";
                    5'd8:  result_byte = "m";
                    5'd9:  result_byte = "o";
                    5'd10: result_byte = "n";
                    5'd11: result_byte = "_";
                    5'd12: result_byte = "u";
                    5'd13: result_byte = "a";
                    5'd14: result_byte = "r";
                    5'd15: result_byte = "t";
                    5'd16: result_byte = 8'h0d;
                    default: result_byte = 8'h0a;
                endcase
            end else begin
                case (index)
                    5'd0:  result_byte = "P";
                    5'd1:  result_byte = "A";
                    5'd2:  result_byte = "S";
                    5'd3:  result_byte = "S";
                    5'd4:  result_byte = " ";
                    5'd5:  result_byte = "c";
                    5'd6:  result_byte = "o";
                    5'd7:  result_byte = "m";
                    5'd8:  result_byte = "m";
                    5'd9:  result_byte = "o";
                    5'd10: result_byte = "n";
                    5'd11: result_byte = "_";
                    5'd12: result_byte = "u";
                    5'd13: result_byte = "a";
                    5'd14: result_byte = "r";
                    5'd15: result_byte = "t";
                    5'd16: result_byte = 8'h0d;
                    default: result_byte = 8'h0a;
                endcase
            end
        end
    endfunction

    wire pattern_tx_issue = (state == ST_PATTERN_TX_ISSUE);
    wire pass_tx_issue = (state == ST_PASS_TX_ISSUE);
    wire fail_tx_issue = (state == ST_FAIL_TX_ISSUE);
    wire tx_issue = pattern_tx_issue || pass_tx_issue || fail_tx_issue;
    wire poll_issue = (state == ST_RX_POLL_ISSUE) ||
                      (state == ST_PASS_DRAIN_ISSUE) ||
                      (state == ST_FAIL_DRAIN_ISSUE);
    wire rx_issue = (state == ST_RX_ISSUE);

    assign cmd_valid = tx_issue || poll_issue || rx_issue;
    assign cmd_write = tx_issue;
    assign cmd_addr = tx_issue ? 8'h00 : (rx_issue ? 8'h04 : 8'h08);
    assign cmd_wdata = pattern_tx_issue ? {24'd0, pattern_byte(pattern_index)} :
                       pass_tx_issue ? {24'd0, result_byte(message_index, 1'b0)} :
                       fail_tx_issue ? {24'd0, result_byte(message_index, 1'b1)} :
                       32'd0;
    assign rsp_ready = (state == ST_PATTERN_TX_WAIT) ||
                       (state == ST_RX_POLL_WAIT) ||
                       (state == ST_RX_WAIT) ||
                       (state == ST_PASS_TX_WAIT) ||
                       (state == ST_PASS_DRAIN_WAIT) ||
                       (state == ST_FAIL_TX_WAIT) ||
                       (state == ST_FAIL_DRAIN_WAIT);

    common_uart #(.CLOCK_HZ(CLK_HZ), .BAUD(BAUD)) uart (
        .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_write(cmd_write), .cmd_addr(cmd_addr), .cmd_wdata(cmd_wdata),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
        .uart_rx(core_rx), .uart_tx(core_tx)
    );

    assign uart_tx = core_tx;
    assign dbg_uart = pass_latched ? 1'b1 :
                      (fail_latched ? fail_blink[23] : 1'b0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_BOOT;
            loopback_enable <= 1'b1;
            pass_latched <= 1'b0;
            fail_latched <= 1'b0;
            pattern_index <= 3'd0;
            message_index <= 5'd0;
            wait_count <= 32'd0;
            fail_blink <= 24'd0;
        end else begin
            fail_blink <= fail_blink + 24'd1;
            case (state)
                ST_BOOT: begin
                    pattern_index <= 3'd0;
                    wait_count <= 32'd0;
                    state <= ST_PATTERN_TX_ISSUE;
                end

                ST_PATTERN_TX_ISSUE:
                    if (cmd_ready) state <= ST_PATTERN_TX_WAIT;

                ST_PATTERN_TX_WAIT:
                    if (rsp_valid) begin
                        if (rsp_error != 0) state <= ST_FAIL_START;
                        else begin
                            wait_count <= 32'd0;
                            state <= ST_RX_POLL_ISSUE;
                        end
                    end

                ST_RX_POLL_ISSUE:
                    if (cmd_ready) state <= ST_RX_POLL_WAIT;

                ST_RX_POLL_WAIT:
                    if (rsp_valid) begin
                        if (rsp_error != 0 || rsp_rdata[3] || rsp_rdata[2])
                            state <= ST_FAIL_START;
                        // The RX stop-bit sample can complete before the TX
                        // engine releases busy at the end of its stop bit.
                        // Keep polling until both the mailbox is valid and TX
                        // is idle, so the next loopback byte is not rejected
                        // as a write-while-busy error.
                        else if (rsp_rdata[1] && !rsp_rdata[0])
                            state <= ST_RX_ISSUE;
                        else
                            state <= ST_RX_POLL_ISSUE;
                    end

                ST_RX_ISSUE:
                    if (cmd_ready) state <= ST_RX_WAIT;

                ST_RX_WAIT:
                    if (rsp_valid) begin
                        if (rsp_error != 0 || rsp_rdata[7:0] != pattern_byte(pattern_index))
                            state <= ST_FAIL_START;
                        else if (pattern_index == PATTERN_LEN-1) begin
                            loopback_enable <= 1'b0;
                            message_index <= 5'd0;
                            wait_count <= 32'd0;
                            state <= ST_PASS_TX_ISSUE;
                        end else begin
                            pattern_index <= pattern_index + 3'd1;
                            wait_count <= 32'd0;
                            state <= ST_PATTERN_TX_ISSUE;
                        end
                    end

                ST_PASS_TX_ISSUE:
                    if (cmd_ready) state <= ST_PASS_TX_WAIT;

                ST_PASS_TX_WAIT:
                    if (rsp_valid) begin
                        if (rsp_error != 0) state <= ST_FAIL_START;
                        else begin
                            wait_count <= 32'd0;
                            state <= ST_PASS_DRAIN_ISSUE;
                        end
                    end

                ST_PASS_DRAIN_ISSUE:
                    if (cmd_ready) state <= ST_PASS_DRAIN_WAIT;

                ST_PASS_DRAIN_WAIT:
                    if (rsp_valid) begin
                        if (rsp_error != 0) state <= ST_FAIL_START;
                        else if (!rsp_rdata[0]) begin
                            if (message_index == MESSAGE_LEN-1) begin
                                pass_latched <= 1'b1;
                                state <= ST_DONE;
                            end else begin
                                message_index <= message_index + 5'd1;
                                wait_count <= 32'd0;
                                state <= ST_PASS_TX_ISSUE;
                            end
                        end else state <= ST_PASS_DRAIN_ISSUE;
                    end

                ST_FAIL_START: begin
                    loopback_enable <= 1'b0;
                    fail_latched <= 1'b1;
                    message_index <= 5'd0;
                    wait_count <= 32'd0;
                    state <= ST_FAIL_TX_ISSUE;
                end

                ST_FAIL_TX_ISSUE:
                    if (cmd_ready) state <= ST_FAIL_TX_WAIT;

                ST_FAIL_TX_WAIT:
                    if (rsp_valid) begin
                        if (rsp_error != 0) state <= ST_FAILED;
                        else begin
                            wait_count <= 32'd0;
                            state <= ST_FAIL_DRAIN_ISSUE;
                        end
                    end

                ST_FAIL_DRAIN_ISSUE:
                    if (cmd_ready) state <= ST_FAIL_DRAIN_WAIT;

                ST_FAIL_DRAIN_WAIT:
                    if (rsp_valid) begin
                        if (rsp_error != 0) state <= ST_FAILED;
                        else if (!rsp_rdata[0]) begin
                            if (message_index == MESSAGE_LEN-1) state <= ST_FAILED;
                            else begin
                                message_index <= message_index + 5'd1;
                                wait_count <= 32'd0;
                                state <= ST_FAIL_TX_ISSUE;
                            end
                        end else state <= ST_FAIL_DRAIN_ISSUE;
                    end

                ST_FAILED, ST_DONE: state <= state;
                default: state <= ST_FAIL_START;
            endcase

            // Bound a missing loopback response and a UART drain failure.
            // Once already reporting failure, a drain timeout leaves the
            // failure indication latched instead of recursively retrying it.
            if ((state == ST_RX_POLL_ISSUE) || (state == ST_RX_POLL_WAIT) ||
                (state == ST_PASS_DRAIN_ISSUE) || (state == ST_PASS_DRAIN_WAIT) ||
                (state == ST_FAIL_DRAIN_ISSUE) || (state == ST_FAIL_DRAIN_WAIT)) begin
                if (wait_count >= TIMEOUT_CYCLES-1) begin
                    if ((state == ST_FAIL_DRAIN_ISSUE) || (state == ST_FAIL_DRAIN_WAIT))
                        state <= ST_FAILED;
                    else
                        state <= ST_FAIL_START;
                end else wait_count <= wait_count + 32'd1;
            end
        end
    end
endmodule

`default_nettype wire
