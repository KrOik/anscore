`default_nettype none
// Minimal synchronous GPIO CSR bank, not an I/O pad primitive.
module common_gpio #(
    parameter integer WIDTH = 16,
    parameter [WIDTH-1:0] RESET_OUTPUT = {WIDTH{1'b0}}
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire cmd_write, input wire [7:0] cmd_addr,
    input wire [31:0] cmd_wdata,
    output reg rsp_valid, input wire rsp_ready,
    output reg [31:0] rsp_rdata, output reg [1:0] rsp_error,
    input wire [WIDTH-1:0] gpio_in,
    output reg [WIDTH-1:0] gpio_out,
    output reg [WIDTH-1:0] gpio_oe
);
    reg [WIDTH-1:0] input_meta, input_sync;
    assign cmd_ready = rst_n && clk_en && !rsp_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_meta <= 0; input_sync <= 0;
            gpio_out <= RESET_OUTPUT; gpio_oe <= 0;
            rsp_valid <= 0; rsp_rdata <= 0; rsp_error <= 0;
        end else if (clk_en) begin
            input_meta <= gpio_in; input_sync <= input_meta;
            if (rsp_valid && rsp_ready) rsp_valid <= 0;
            if (cmd_valid && cmd_ready) begin
                rsp_valid <= 1; rsp_rdata <= 0; rsp_error <= 0;
                case (cmd_addr)
                    8'h00: begin
                        if (cmd_write) rsp_error <= 2'd2;
                        else rsp_rdata <= input_sync;
                    end
                    8'h04: begin
                        if (cmd_write) gpio_out <= cmd_wdata[WIDTH-1:0];
                        else rsp_rdata <= gpio_out;
                    end
                    8'h08: begin
                        if (cmd_write) gpio_oe <= cmd_wdata[WIDTH-1:0];
                        else rsp_rdata <= gpio_oe;
                    end
                    8'h0c: begin
                        if (cmd_write) gpio_out <= gpio_out | cmd_wdata[WIDTH-1:0];
                        else rsp_error <= 2'd2;
                    end
                    8'h10: begin
                        if (cmd_write) gpio_out <= gpio_out & ~cmd_wdata[WIDTH-1:0];
                        else rsp_error <= 2'd2;
                    end
                    8'h14: begin
                        if (cmd_write) gpio_out <= gpio_out ^ cmd_wdata[WIDTH-1:0];
                        else rsp_error <= 2'd2;
                    end
                    default: rsp_error <= 2'd1;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
