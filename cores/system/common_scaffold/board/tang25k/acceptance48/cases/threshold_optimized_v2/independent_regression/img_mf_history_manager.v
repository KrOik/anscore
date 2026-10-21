// Development draft, unverified. Metadata ownership only; no image RAM is implied.
// Small slot metadata arrays may be registers. Pixel storage belongs to an adapter.
module img_mf_history_manager #(
    parameter SLOT_COUNT = 4, parameter SLOT_WIDTH = 2, parameter FRAME_WIDTH = 16
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire [2:0] cmd_opcode, input wire [SLOT_WIDTH-1:0] cmd_slot,
    input wire [FRAME_WIDTH-1:0] cmd_frameid,
    input wire [15:0] cmd_width, input wire [15:0] cmd_height,
    input wire [31:0] cmd_sample_count,
    output reg rsp_valid, input wire rsp_ready,
    output reg [2:0] rsp_opcode, output reg [SLOT_WIDTH-1:0] rsp_slot,
    output reg [FRAME_WIDTH-1:0] rsp_frameid,
    output reg [15:0] rsp_width, output reg [15:0] rsp_height,
    output reg [31:0] rsp_sample_count, output reg [31:0] rsp_sequence,
    output reg [1:0] rsp_state, output reg [7:0] rsp_error,
    output reg [7:0] error_code
);
    // Opcodes: 0 allocate EMPTY->WRITING, 1 commit WRITING->READY,
    // 2 query, 3 release, 4 invalidate-all; 5..7 explicitly unsupported.
    // State: 0 EMPTY, 1 WRITING, 2 READY. Response is exactly once per command.
    reg [1:0] slot_state [0:SLOT_COUNT-1];
    reg [FRAME_WIDTH-1:0] slot_frame [0:SLOT_COUNT-1];
    reg [15:0] slot_width [0:SLOT_COUNT-1];
    reg [15:0] slot_height [0:SLOT_COUNT-1];
    reg [31:0] slot_samples [0:SLOT_COUNT-1];
    reg [31:0] slot_sequence [0:SLOT_COUNT-1];
    reg [31:0] next_sequence;
    reg [7:0] command_error;
    integer i;
    wire parameters_ok = SLOT_COUNT > 0 && SLOT_COUNT <= 16 && SLOT_WIDTH > 0 && SLOT_WIDTH <= 4 && SLOT_COUNT <= (1 << SLOT_WIDTH);
    wire [31:0] requested_samples = {16'd0,cmd_width} * {16'd0,cmd_height};
    assign cmd_ready = rst_n && clk_en && (!rsp_valid || rsp_ready);

    always @* begin
        command_error = 8'd0;
        if (!parameters_ok) command_error = 8'h40;
        else if (cmd_opcode >= 3'd5) command_error = 8'h08;
        else if (cmd_opcode != 3'd4) begin
            if (cmd_slot >= SLOT_COUNT) command_error = 8'h01;
            else case (cmd_opcode)
                3'd0: begin
                    if (slot_state[cmd_slot] != 0) command_error = 8'h02;
                    else if (cmd_width == 0 || cmd_height == 0) command_error = 8'h04;
                end
                3'd1: begin
                    if (slot_state[cmd_slot] != 1) command_error = 8'h02;
                    else if (slot_frame[cmd_slot] != cmd_frameid) command_error = 8'h10;
                    else if (slot_samples[cmd_slot] != cmd_sample_count) command_error = 8'h04;
                end
                3'd2: if (slot_state[cmd_slot] == 0) command_error = 8'h02;
                3'd3: if (slot_state[cmd_slot] == 0) command_error = 8'h02;
                default: command_error = 8'h08;
            endcase
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_valid <= 0; rsp_opcode <= 0; rsp_slot <= 0; rsp_frameid <= 0;
            rsp_width <= 0; rsp_height <= 0; rsp_sample_count <= 0;
            rsp_sequence <= 0; rsp_state <= 0; rsp_error <= 0; error_code <= 0;
            next_sequence <= 0;
            for (i=0;i<SLOT_COUNT;i=i+1) begin
                slot_state[i] <= 0; slot_frame[i] <= 0; slot_width[i] <= 0;
                slot_height[i] <= 0; slot_samples[i] <= 0; slot_sequence[i] <= 0;
            end
        end else if (clk_en) begin
            if (rsp_valid && rsp_ready) rsp_valid <= 1'b0;
            if (cmd_valid && cmd_ready) begin
                rsp_valid <= 1'b1; rsp_opcode <= cmd_opcode; rsp_slot <= cmd_slot;
                rsp_frameid <= cmd_frameid; rsp_width <= 0; rsp_height <= 0;
                rsp_sample_count <= 0; rsp_sequence <= 0; rsp_state <= 0;
                rsp_error <= command_error; error_code <= error_code | command_error;
                if (command_error == 0) begin
                    if (cmd_opcode == 3'd4) begin
                        for (i=0;i<SLOT_COUNT;i=i+1) slot_state[i] <= 0;
                    end else begin
                        rsp_frameid <= slot_frame[cmd_slot];
                        rsp_width <= slot_width[cmd_slot]; rsp_height <= slot_height[cmd_slot];
                        rsp_sample_count <= slot_samples[cmd_slot];
                        rsp_sequence <= slot_sequence[cmd_slot]; rsp_state <= slot_state[cmd_slot];
                        case (cmd_opcode)
                            3'd0: begin
                                slot_state[cmd_slot] <= 1; slot_frame[cmd_slot] <= cmd_frameid;
                                slot_width[cmd_slot] <= cmd_width; slot_height[cmd_slot] <= cmd_height;
                                slot_samples[cmd_slot] <= requested_samples;
                                slot_sequence[cmd_slot] <= next_sequence;
                                rsp_frameid <= cmd_frameid; rsp_width <= cmd_width; rsp_height <= cmd_height;
                                rsp_sample_count <= requested_samples; rsp_sequence <= next_sequence;
                                rsp_state <= 1; next_sequence <= next_sequence + 32'd1;
                            end
                            3'd1: begin slot_state[cmd_slot] <= 2; rsp_state <= 2; end
                            3'd3: begin slot_state[cmd_slot] <= 0; rsp_state <= 0; end
                            default: begin end
                        endcase
                    end
                end
            end
        end
    end
endmodule
