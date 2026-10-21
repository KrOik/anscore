`default_nettype none
// Minimal reload down-counter; each clk_en pulse is one timer tick.
module common_timer #(
    parameter integer COUNTER_WIDTH = 32
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire cmd_write, input wire [7:0] cmd_addr,
    input wire [31:0] cmd_wdata,
    output reg rsp_valid, input wire rsp_ready,
    output reg [31:0] rsp_rdata, output reg [1:0] rsp_error,
    output wire timer_irq
);
    reg enabled, periodic, pending;
    reg [COUNTER_WIDTH-1:0] reload_value, remaining;
    wire oversized = |(cmd_wdata >> COUNTER_WIDTH);
    wire expire_now = enabled && (remaining == 1);
    assign cmd_ready = rst_n && clk_en && !rsp_valid;
    assign timer_irq = pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enabled <= 0; periodic <= 0; pending <= 0;
            reload_value <= 0; remaining <= 0;
            rsp_valid <= 0; rsp_rdata <= 0; rsp_error <= 0;
        end else if (clk_en) begin
            if (enabled) begin
                if (expire_now) begin
                    pending <= 1;
                    if (periodic) remaining <= reload_value;
                    else begin enabled <= 0; remaining <= 0; end
                end else remaining <= remaining - 1'b1;
            end
            if (rsp_valid && rsp_ready) rsp_valid <= 0;
            if (cmd_valid && cmd_ready) begin
                rsp_valid <= 1; rsp_rdata <= 0; rsp_error <= 0;
                case (cmd_addr)
                    8'h00: begin
                        if (!cmd_write) rsp_rdata <= {30'b0, periodic, enabled};
                        else if (|cmd_wdata[31:2] || (cmd_wdata[0] && reload_value == 0))
                            rsp_error <= 2'd3;
                        else begin
                            enabled <= cmd_wdata[0]; periodic <= cmd_wdata[1];
                            remaining <= cmd_wdata[0] ? reload_value : 0;
                        end
                    end
                    8'h04: begin
                        if (!cmd_write) rsp_rdata <= reload_value;
                        else if (oversized || cmd_wdata == 0) rsp_error <= 2'd3;
                        else begin
                            reload_value <= cmd_wdata[COUNTER_WIDTH-1:0];
                            remaining <= enabled ? cmd_wdata[COUNTER_WIDTH-1:0] : 0;
                        end
                    end
                    8'h08: begin
                        if (cmd_write) rsp_error <= 2'd2;
                        else rsp_rdata <= remaining;
                    end
                    8'h0c: begin
                        if (!cmd_write) rsp_rdata <= {31'b0, pending};
                        else if (|cmd_wdata[31:1]) rsp_error <= 2'd3;
                        // A new expiration wins over software clear.
                        else if (cmd_wdata[0]) pending <= expire_now;
                    end
                    default: rsp_error <= 2'd1;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
