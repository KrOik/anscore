`default_nettype none
// Minimal rising-edge interrupt collector with two-sample input synchronization.
module common_irq #(
    parameter integer WIDTH = 8
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire cmd_write, input wire [7:0] cmd_addr,
    input wire [31:0] cmd_wdata,
    output reg rsp_valid, input wire rsp_ready,
    output reg [31:0] rsp_rdata, output reg [1:0] rsp_error,
    input wire [WIDTH-1:0] irq_in,
    output wire irq_any
);
    reg [WIDTH-1:0] input_meta, input_sync, input_previous;
    reg [WIDTH-1:0] mask, pending;
    wire [WIDTH-1:0] rising = input_sync & ~input_previous;
    assign cmd_ready = rst_n && clk_en && !rsp_valid;
    assign irq_any = |(pending & mask);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_meta <= 0; input_sync <= 0; input_previous <= 0;
            mask <= 0; pending <= 0;
            rsp_valid <= 0; rsp_rdata <= 0; rsp_error <= 0;
        end else if (clk_en) begin
            input_meta <= irq_in; input_sync <= input_meta; input_previous <= input_sync;
            pending <= pending | rising;
            if (rsp_valid && rsp_ready) rsp_valid <= 0;
            if (cmd_valid && cmd_ready) begin
                rsp_valid <= 1; rsp_rdata <= 0; rsp_error <= 0;
                case (cmd_addr)
                    8'h00: begin
                        if (cmd_write) mask <= cmd_wdata[WIDTH-1:0];
                        else rsp_rdata <= mask;
                    end
                    8'h04: begin
                        if (cmd_write) pending <= (pending & ~cmd_wdata[WIDTH-1:0]) | rising;
                        else rsp_rdata <= pending;
                    end
                    8'h08: begin
                        if (cmd_write) rsp_error <= 2'd2;
                        else rsp_rdata <= input_sync;
                    end
                    8'h0c: begin
                        if (cmd_write) rsp_error <= 2'd2;
                        else rsp_rdata <= pending & mask;
                    end
                    default: rsp_error <= 2'd1;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
