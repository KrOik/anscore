// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Single-level reversible CDF 5/3 lifting, one block at a time.
module cdf53_block #(
    parameter integer SAMPLE_W = 16,
    parameter integer BLOCK_LEN = 16,
    parameter integer INVERSE = 0
) (
    input  wire clk,
    input  wire rst,
    input  wire s_valid,
    output wire s_ready,
    input  wire signed [SAMPLE_W+1:0] s_data,
    output wire m_valid,
    input  wire m_ready,
    output wire signed [SAMPLE_W+1:0] m_data,
    output wire m_last,
    output wire m_error
);
    localparam integer CW = SAMPLE_W + 2;
    localparam integer WW = CW + 3;
    localparam integer AW = (BLOCK_LEN < 2) ? 1 : $clog2(BLOCK_LEN);
    localparam integer LOW_LEN = (BLOCK_LEN + 1) / 2;
    generate if (SAMPLE_W < 2 || SAMPLE_W > 24 || BLOCK_LEN < 1 ||
                 BLOCK_LEN > 256 || (INVERSE != 0 && INVERSE != 1)) begin : g_invalid
        cdf53_invalid_parameter__see_README invalid_configuration();
    end endgenerate
    localparam [3:0] LOAD=0, READ_C=1, READ_L=2, READ_R=3,
        CALC=4, WRITE=5, OUT_READ=6, OUT_CAPTURE=7, OUT_HOLD=8;

    reg [3:0] state;
    reg [AW-1:0] load_index, target, out_index;
    reg update_step;
    reg block_error;
    reg signed [WW-1:0] mem [0:BLOCK_LEN-1];
    reg signed [WW-1:0] read_data, center, left, result;
    reg signed [CW-1:0] output_data;
    reg read_en, write_en;
    reg [AW-1:0] read_addr, write_addr;
    reg signed [WW-1:0] write_data;
    wire signed [WW:0] neighbor_sum =
        $signed({left[WW-1],left}) + $signed({read_data[WW-1],read_data});
    wire signed [WW:0] delta = update_step ?
        ((neighbor_sum + $signed({{(WW-1){1'b0}},2'b10})) >>> 2) :
        (neighbor_sum >>> 1);
    // Forward: predict subtracts, update adds; inverse reverses both.
    wire do_subtract = INVERSE ? update_step : !update_step;
    wire signed [WW:0] computed = do_subtract ?
        ($signed({center[WW-1],center}) - delta) :
        ($signed({center[WW-1],center}) + delta);
    wire output_overflow = read_data[WW-1:CW-1] !=
        {(WW-CW+1){read_data[CW-1]}};
    wire input_out_of_range = s_data[CW-1:SAMPLE_W-1] !=
        {(CW-SAMPLE_W+1){s_data[SAMPLE_W-1]}};

    assign s_ready = !rst && state == LOAD;
    assign m_valid = !rst && state == OUT_HOLD;
    assign m_data = output_data;
    assign m_last = out_index == BLOCK_LEN-1;
    assign m_error = block_error;

    // A single synchronous read port and single write port; no array reset.
    always @(posedge clk) begin
        if (write_en) mem[write_addr] <= write_data;
        if (read_en) read_data <= mem[read_addr];
    end

    always @* begin
        read_en = 1'b0;
        write_en = 1'b0;
        read_addr = {AW{1'b0}};
        write_addr = target;
        write_data = result;
        if (!rst) begin
            case (state)
                LOAD: if (s_valid) begin
                    write_en = 1'b1;
                    // Inverse input arrives in [low...,high...] order.
                    if (INVERSE)
                        write_addr = (load_index < LOW_LEN) ?
                            (load_index << 1) : (((load_index - LOW_LEN) << 1) + 1);
                    else write_addr = load_index;
                    write_data = {{(WW-CW){s_data[CW-1]}},s_data};
                end
                READ_C: begin read_en=1'b1; read_addr=target; end
                READ_L: begin
                    read_en=1'b1;
                    // Whole-sample symmetric extension repeats the nearest
                    // opposite-parity sample at either block boundary.
                    read_addr = (target == 0) ? 1 : target-1'b1;
                end
                READ_R: begin
                    read_en=1'b1;
                    read_addr = (target == BLOCK_LEN-1) ? target-1'b1 : target+1'b1;
                end
                WRITE: write_en=1'b1;
                OUT_READ: begin
                    read_en=1'b1;
                    if (INVERSE) read_addr=out_index;
                    else read_addr = (out_index < LOW_LEN) ?
                        (out_index << 1) : (((out_index - LOW_LEN) << 1) + 1);
                end
                default: begin end
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= LOAD;
            load_index <= 0;
            out_index <= 0;
            target <= 0;
            update_step <= 0;
            block_error <= 0;
            output_data <= 0;
            center <= 0;
            left <= 0;
            result <= 0;
        end else begin
            case (state)
                LOAD: if (s_valid) begin
                    if (load_index == 0)
                        block_error <= !INVERSE && input_out_of_range;
                    else if (!INVERSE && input_out_of_range)
                        block_error <= 1'b1;
                    if (load_index == BLOCK_LEN-1) begin
                        load_index <= 0;
                        out_index <= 0;
                        update_step <= INVERSE != 0;
                        target <= INVERSE ? 0 : 1;
                        state <= (BLOCK_LEN == 1) ? OUT_READ : READ_C;
                    end else load_index <= load_index+1'b1;
                end
                READ_C: state <= READ_L;
                READ_L: begin center <= read_data; state <= READ_R; end
                READ_R: begin left <= read_data; state <= CALC; end
                CALC: begin result <= computed[WW-1:0]; state <= WRITE; end
                WRITE: begin
                    if (result[WW-1:CW-1] != {(WW-CW+1){result[CW-1]}})
                        block_error <= 1'b1;
                    if (target >= BLOCK_LEN-2) begin
                        if (update_step == (INVERSE != 0)) begin
                            update_step <= !update_step;
                            target <= INVERSE ? 1 : 0;
                            state <= READ_C;
                        end else state <= OUT_READ;
                    end else begin target <= target+2; state <= READ_C; end
                end
                OUT_READ: state <= OUT_CAPTURE;
                OUT_CAPTURE: begin
                    if (output_overflow) begin
                        output_data <= read_data[WW-1] ?
                            {1'b1,{(CW-1){1'b0}}} : {1'b0,{(CW-1){1'b1}}};
                        block_error <= 1'b1;
                    end else output_data <= read_data[CW-1:0];
                    state <= OUT_HOLD;
                end
                OUT_HOLD: if (m_ready) begin
                    if (out_index == BLOCK_LEN-1) state <= LOAD;
                    else begin out_index <= out_index+1'b1; state <= OUT_READ; end
                end
                default: state <= LOAD;
            endcase
        end
    end
endmodule
