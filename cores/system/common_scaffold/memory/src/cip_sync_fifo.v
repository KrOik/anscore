// Single-clock FIFO with synchronous RAM reads and a registered output slot.
// DEPTH counts total buffered words, including the output slot. DEPTH=1 works.
// No asynchronous coefficient/register-array read is used.
module cip_sync_fifo #(
    parameter DATA_WIDTH = 32,
    parameter DEPTH = 16,
    parameter LEVEL_WIDTH = (DEPTH < 2) ? 1 : $clog2(DEPTH + 1)
)(
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [DATA_WIDTH-1:0] in_data,
    output reg out_valid, input wire out_ready,
    output reg [DATA_WIDTH-1:0] out_data,
    output reg [LEVEL_WIDTH-1:0] level,
    output wire full, output wire empty
);
    localparam PTR_WIDTH = (DEPTH < 2) ? 1 : $clog2(DEPTH);
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr, rd_ptr;
    reg [LEVEL_WIDTH-1:0] ram_count;
    wire output_fire = out_valid && out_ready;
    wire input_fire = in_valid && in_ready;
    wire output_slot = !out_valid || out_ready;
    wire ram_pop = output_slot && ram_count != 0;
    wire bypass = output_slot && ram_count == 0 && input_fire;
    wire ram_push = input_fire && !bypass;
    assign in_ready = rst_n && (level < DEPTH || output_fire);
    assign full = level == DEPTH;
    assign empty = level == 0;
    // Synchronous storage and output; memory contents need no reset.
    always @(posedge clk) begin
        if (rst_n && clk_en) begin
            if (ram_push) mem[wr_ptr] <= in_data;
            if (ram_pop) out_data <= mem[rd_ptr];
            else if (bypass) out_data <= in_data;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0; level <= 0; ram_count <= 0;
            wr_ptr <= 0; rd_ptr <= 0;
        end else if (clk_en) begin
            if (output_slot) out_valid <= ram_pop || bypass;
            case ({input_fire, output_fire})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: ;
            endcase
            case ({ram_push, ram_pop})
                2'b10: ram_count <= ram_count + 1'b1;
                2'b01: ram_count <= ram_count - 1'b1;
                default: ;
            endcase
            if (ram_push) wr_ptr <= wr_ptr == DEPTH-1 ? 0 : wr_ptr + 1'b1;
            if (ram_pop) rd_ptr <= rd_ptr == DEPTH-1 ? 0 : rd_ptr + 1'b1;
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH < 1 || DEPTH < 1 || LEVEL_WIDTH < $clog2(DEPTH + 1))
            $fatal(1, "cip_sync_fifo invalid parameters");
    end
`endif
endmodule
