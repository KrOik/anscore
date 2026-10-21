// CE-qualified elastic ready/valid pipeline. All data and markers advance
// atomically through PIPE_STAGES registers. A common advance enable avoids
// a combinational ready ripple across all stages; full output stalls freeze all.
module img_filter_stream_register #(
    parameter DATA_W = 8,
    parameter PIPE_STAGES = 1
)(
    input wire clk, rst_n, clk_en,
    input wire [DATA_W-1:0] s_data,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output wire [DATA_W-1:0] m_data,
    output wire m_valid, m_sof, m_eol,
    input wire m_ready
);
    reg [DATA_W-1:0] data_pipe [0:PIPE_STAGES-1];
    reg valid_pipe [0:PIPE_STAGES-1];
    reg sof_pipe [0:PIPE_STAGES-1];
    reg eol_pipe [0:PIPE_STAGES-1];
    wire [PIPE_STAGES:0] ready_chain;
    wire pipeline_advance=!valid_pipe[PIPE_STAGES-1] || m_ready;
    assign ready_chain[PIPE_STAGES] = m_ready;
    assign s_ready = rst_n && clk_en && ready_chain[0];
    assign m_data = data_pipe[PIPE_STAGES-1];
    assign m_valid = valid_pipe[PIPE_STAGES-1];
    assign m_sof = sof_pipe[PIPE_STAGES-1];
    assign m_eol = eol_pipe[PIPE_STAGES-1];

    genvar stage;
    generate
        for (stage = 0; stage < PIPE_STAGES; stage = stage + 1) begin : stage_gen
            assign ready_chain[stage] = pipeline_advance;
            if (stage == 0) begin : input_stage
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        data_pipe[stage] <= {DATA_W{1'b0}};
                        valid_pipe[stage] <= 1'b0;
                        sof_pipe[stage] <= 1'b0;
                        eol_pipe[stage] <= 1'b0;
                    end else if (clk_en && ready_chain[stage]) begin
                        valid_pipe[stage] <= s_valid;
                        if (s_valid) begin
                            data_pipe[stage] <= s_data;
                            sof_pipe[stage] <= s_sof;
                            eol_pipe[stage] <= s_eol;
                        end
                    end
                end
            end else begin : downstream_stage
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        data_pipe[stage] <= {DATA_W{1'b0}};
                        valid_pipe[stage] <= 1'b0;
                        sof_pipe[stage] <= 1'b0;
                        eol_pipe[stage] <= 1'b0;
                    end else if (clk_en && ready_chain[stage]) begin
                        valid_pipe[stage] <= valid_pipe[stage-1];
                        if (valid_pipe[stage-1]) begin
                            data_pipe[stage] <= data_pipe[stage-1];
                            sof_pipe[stage] <= sof_pipe[stage-1];
                            eol_pipe[stage] <= eol_pipe[stage-1];
                        end
                    end
                end
            end
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (DATA_W < 1 || PIPE_STAGES < 1)
            $fatal(1, "img_filter_stream_register: invalid width/depth");
    end
`endif
endmodule
