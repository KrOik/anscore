`default_nettype none
// Minimal single-channel edge-aligned PWM, configuration restarts the phase.
module common_pwm #(
    parameter integer COUNTER_WIDTH = 16,
    parameter [COUNTER_WIDTH-1:0] RESET_PERIOD = 1000
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire cmd_write, input wire [7:0] cmd_addr,
    input wire [31:0] cmd_wdata,
    output reg rsp_valid, input wire rsp_ready,
    output reg [31:0] rsp_rdata, output reg [1:0] rsp_error,
    output wire pwm_out
);
    reg enabled;
    reg [COUNTER_WIDTH-1:0] period, duty, counter;
    wire oversized = |(cmd_wdata >> COUNTER_WIDTH);
    assign cmd_ready = rst_n && clk_en && !rsp_valid;
    assign pwm_out = enabled && (counter < duty);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enabled <= 0; period <= RESET_PERIOD; duty <= 0; counter <= 0;
            rsp_valid <= 0; rsp_rdata <= 0; rsp_error <= 0;
        end else if (clk_en) begin
            if (enabled) begin
                if (counter == period - 1'b1) counter <= 0;
                else counter <= counter + 1'b1;
            end
            if (rsp_valid && rsp_ready) rsp_valid <= 0;
            if (cmd_valid && cmd_ready) begin
                rsp_valid <= 1; rsp_rdata <= 0; rsp_error <= 0;
                case (cmd_addr)
                    8'h00: begin
                        if (!cmd_write) rsp_rdata <= {31'b0, enabled};
                        else if (|cmd_wdata[31:1]) rsp_error <= 2'd3;
                        else begin enabled <= cmd_wdata[0]; counter <= 0; end
                    end
                    8'h04: begin
                        if (!cmd_write) rsp_rdata <= period;
                        else if (oversized || cmd_wdata == 0 || cmd_wdata < duty)
                            rsp_error <= 2'd3;
                        else begin period <= cmd_wdata[COUNTER_WIDTH-1:0]; counter <= 0; end
                    end
                    8'h08: begin
                        if (!cmd_write) rsp_rdata <= duty;
                        else if (oversized || cmd_wdata > period) rsp_error <= 2'd3;
                        else begin duty <= cmd_wdata[COUNTER_WIDTH-1:0]; counter <= 0; end
                    end
                    8'h0c: begin
                        if (cmd_write) rsp_error <= 2'd2;
                        else rsp_rdata <= counter;
                    end
                    default: rsp_error <= 2'd1;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
