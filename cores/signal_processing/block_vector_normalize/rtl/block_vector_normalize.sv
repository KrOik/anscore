// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Bounded framed L2 normalization using the existing RNE root and divider.
module block_vector_normalize #(
    parameter integer DATA_W=16,
    parameter integer MAX_LEN=16,
    parameter integer FRAC=16,
    parameter integer TAG_W=8,
    localparam integer COUNT_W=(MAX_LEN<2)?1:$clog2(MAX_LEN+1),
    localparam integer INDEX_W=(MAX_LEN<2)?1:$clog2(MAX_LEN),
    localparam integer ENERGY_W=2*DATA_W+((MAX_LEN<2)?0:$clog2(MAX_LEN))
) (
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire signed [DATA_W-1:0] s_data,
    input wire s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output reg signed [FRAC+1:0] m_data,
    output reg m_keep,
    output wire m_last,
    output reg [1:0] m_status,
    output reg [COUNT_W-1:0] m_count,
    output wire [INDEX_W-1:0] m_index,
    output reg [ENERGY_W-1:0] m_energy,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer RF=FRAC+2;
    localparam integer RN=(ENERGY_W+2*RF+1)/2;
    localparam integer BW=RN+1;
    localparam integer AW=DATA_W+RF;
    localparam [3:0] COLLECT=0,ACCUMULATE=1,PREPARE=2,ROOT_OFFER=3,
        ROOT_WAIT=4,MEM_READ=5,DIV_OFFER=6,DIV_WAIT=7,ZERO_SETUP=8,EMIT=9;
    localparam [1:0] OK=0,EMPTY=1,ZERO=2,OVERFLOW=3;
    generate if(DATA_W<2 || DATA_W>24 || MAX_LEN<1 || MAX_LEN>64 ||
                FRAC<0 || FRAC>22 || TAG_W<1 || TAG_W>32) begin : g_invalid
        block_vector_normalize_invalid_parameter__see_README invalid_configuration();
    end endgenerate

    reg [3:0] state;
    reg first,overflow,pending_last;
    reg [COUNT_W-1:0] count;
    reg [INDEX_W-1:0] index;
    reg signed [DATA_W-1:0] components[0:MAX_LEN-1];
    reg signed [DATA_W-1:0] power_input,sample_q;
    reg [ENERGY_W-1:0] energy;
    reg [BW-1:0] norm_root;
    wire signed [2*DATA_W-1:0] square=power_input*power_input;
    wire [ENERGY_W-1:0] square_extended={{(ENERGY_W-2*DATA_W){1'b0}},$unsigned(square)};
    wire root_ready,root_valid,div_ready,div_valid;
    wire [BW-1:0] root_data;
    wire [1:0] root_user_unused,div_user_unused;
    wire [FRAC+1:0] div_data;
    wire signed [AW-1:0] scaled_sample={sample_q,{RF{1'b0}}};
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_index=index;
    assign m_last=!m_keep || index==count-1'b1;

    // Synchronous read, capture write; processing and ingestion are disjoint.
    always @(posedge clk) begin
        if(!rst) begin
            if(state==MEM_READ) sample_q<=components[index];
            if(state==COLLECT && s_valid && s_ready && s_keep && count<MAX_LEN)
                components[count[INDEX_W-1:0]]<=s_data;
        end
    end
    fp_sqrt_iter #(.IN_W(ENERGY_W),.FB(RF)) root_engine (
        .clk(clk),.rst_n(!rst),.s_tdata(energy),
        .s_tvalid(!rst && state==ROOT_OFFER),.s_tready(root_ready),
        .m_tdata(root_data),.m_tuser(root_user_unused),.m_tvalid(root_valid),
        .m_tready(!rst && state==ROOT_WAIT)
    );
    fp_div_iter #(.AW(AW),.BW(BW),.FB(FRAC),.OUT_W(FRAC+2)) divide_engine (
        .clk(clk),.rst_n(!rst),.s_tdata({norm_root,scaled_sample}),
        .s_tvalid(!rst && state==DIV_OFFER),.s_tready(div_ready),
        .m_tdata(div_data),.m_tuser(div_user_unused),.m_tvalid(div_valid),
        .m_tready(!rst && state==DIV_WAIT)
    );
    always @(posedge clk) begin
        if(rst) begin
            state<=COLLECT;first<=1;overflow<=0;pending_last<=0;
            count<=0;index<=0;energy<=0;
            m_data<=0;m_keep<=0;m_status<=0;m_count<=0;m_energy<=0;m_tag<=0;
        end else begin
            case(state)
                COLLECT: if(s_valid) begin
                    if(first) begin m_tag<=s_tag;first<=0;end
                    if(s_keep && count<MAX_LEN) begin
                        power_input<=s_data;pending_last<=s_last;count<=count+1'b1;
                        state<=ACCUMULATE;
                    end else begin
                        if(s_keep) overflow<=1;
                        if(s_last) state<=PREPARE;
                    end
                end
                ACCUMULATE: begin
                    energy<=energy+square_extended;
                    state<=pending_last?PREPARE:COLLECT;
                end
                PREPARE: begin
                    index<=0;
                    if(overflow || count==0) begin
                        m_keep<=0;m_data<=0;m_count<=0;m_energy<=0;
                        m_status<=overflow?OVERFLOW:EMPTY;state<=EMIT;
                    end else begin
                        m_keep<=1;m_count<=count;m_energy<=energy;
                        m_status<=(energy==0)?ZERO:OK;
                        state<=(energy==0)?ZERO_SETUP:ROOT_OFFER;
                    end
                end
                ROOT_OFFER: if(root_ready) state<=ROOT_WAIT;
                ROOT_WAIT: if(root_valid) begin norm_root<=root_data;state<=MEM_READ;end
                MEM_READ: state<=DIV_OFFER;
                DIV_OFFER: if(div_ready) state<=DIV_WAIT;
                DIV_WAIT: if(div_valid) begin m_data<=div_data;state<=EMIT;end
                ZERO_SETUP: begin m_data<=0;state<=EMIT;end
                EMIT: if(m_ready) begin
                    if(m_last) begin
                        state<=COLLECT;first<=1;overflow<=0;count<=0;energy<=0;index<=0;
                    end else begin
                        index<=index+1'b1;
                        state<=(m_status==ZERO)?ZERO_SETUP:MEM_READ;
                    end
                end
                default: state<=COLLECT;
            endcase
        end
    end
endmodule
