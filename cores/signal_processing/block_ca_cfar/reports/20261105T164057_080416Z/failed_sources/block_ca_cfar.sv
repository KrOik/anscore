// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE implementation. Integer-power CA-CFAR; see README.md.
module block_ca_cfar #(
    parameter integer MAX_SAMPLES=256,
    parameter integer DATA_W=16,
    parameter integer TRAINING=4,
    parameter integer GUARD=2,
    parameter integer ALPHA_W=16,
    parameter integer TAG_W=8
)(
    input wire clk, input wire rst_n,
    input wire c_valid, output wire c_ready,
    input wire [31:0] c_length,
    input wire [ALPHA_W-1:0] c_alpha_num, c_alpha_den,
    input wire [TAG_W-1:0] c_tag,
    input wire s_valid, output wire s_ready,
    input wire [DATA_W-1:0] s_data,
    output reg m_valid, input wire m_ready,
    output reg [31:0] m_index,
    output reg [DATA_W-1:0] m_sample,
    output reg [DATA_W+$clog2(2*TRAINING)-1:0] m_noise_sum,
    output reg m_eligible, m_detect, m_last, m_error,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer AW=(MAX_SAMPLES<=1)?1:$clog2(MAX_SAMPLES);
    localparam integer LW=(MAX_SAMPLES<=1)?1:$clog2(MAX_SAMPLES+1);
    localparam integer RW=(2*TRAINING<=2)?1:$clog2(2*TRAINING);
    localparam integer SW=DATA_W+$clog2(2*TRAINING);
    localparam integer PW=DATA_W+ALPHA_W;
    localparam integer CW=SW+ALPHA_W+1;
    localparam integer HALO=TRAINING+GUARD;
    localparam [3:0] IDLE=0, LOAD=1, READ_CUT=2, GOT_CUT=3,
        READ_REF=4, GOT_REF=5, MUL=6, COMPARE=7, HOLD=8;
    reg [3:0] state;
    reg [LW-1:0] length;
    reg [AW-1:0] wr_index, cut_index;
    reg [RW-1:0] ref_index;
    reg [ALPHA_W-1:0] alpha_num, alpha_den;
    reg [TAG_W-1:0] tag;
    reg [DATA_W-1:0] mem [0:MAX_SAMPLES-1];
    reg [DATA_W-1:0] read_data, cut_data;
    reg [SW-1:0] noise_sum;
    reg [PW-1:0] cut_times_den;
    reg [CW-1:0] noise_times_num;
    wire [CW-1:0] scaled_cut = {{(CW-PW){1'b0}},cut_times_den} * (2*TRAINING);
    wire [31:0] cut32={{(32-AW){1'b0}},cut_index};
    wire [31:0] length32={{(32-LW){1'b0}},length};
    wire eligible=(cut32>=HALO) && (cut32+HALO<length32);
    wire [SW-1:0] next_sum=noise_sum+{{(SW-DATA_W){1'b0}},read_data};
    reg [AW-1:0] read_addr;

    generate if (MAX_SAMPLES<1 || MAX_SAMPLES>1024 || DATA_W<1 || DATA_W>32 ||
                 TRAINING<1 || TRAINING>16 || GUARD<0 || GUARD>16 ||
                 ALPHA_W<1 || ALPHA_W>16 || TAG_W<1 || TAG_W>32) begin: bad
        block_ca_cfar_invalid_parameters__see_README invalid();
    end endgenerate

    assign c_ready=rst_n && state==IDLE;
    assign s_ready=rst_n && state==LOAD;
    // Only eligible cells enter READ_REF, so every addressed reference exists.
    always @* begin
        read_addr=cut_index;
        if (state==READ_REF) begin
            if (ref_index<TRAINING)
                read_addr=cut_index-HALO+ref_index;
            else
                read_addr=cut_index+GUARD+1+(ref_index-TRAINING);
        end
    end
    // One synchronous port, one request per read state. No reset of payload RAM.
    always @(posedge clk) begin
        if (rst_n) begin
            if (s_valid && s_ready) mem[wr_index]<=s_data;
            else if (state==READ_CUT || state==READ_REF) read_data<=mem[read_addr];
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; length<=0; wr_index<=0; cut_index<=0; ref_index<=0;
            alpha_num<=0; alpha_den<=0; tag<=0; cut_data<=0; noise_sum<=0;
            cut_times_den<=0; noise_times_num<=0;
            m_valid<=0; m_index<=0; m_sample<=0; m_noise_sum<=0;
            m_eligible<=0; m_detect<=0; m_last<=0; m_error<=0; m_tag<=0;
        end else case (state)
            IDLE: if (c_valid && c_ready) begin
                tag<=c_tag; alpha_num<=c_alpha_num; alpha_den<=c_alpha_den;
                if (c_length==0 || c_length>MAX_SAMPLES || c_alpha_den==0) begin
                    m_valid<=1; m_error<=1; m_last<=1; m_tag<=c_tag;
                    m_index<=0; m_sample<=0; m_noise_sum<=0;
                    m_eligible<=0; m_detect<=0; state<=HOLD;
                end else begin
                    length<=c_length[LW-1:0]; wr_index<=0; cut_index<=0;
                    state<=LOAD;
                end
            end
            LOAD: if (s_valid && s_ready) begin
                if (wr_index==length-1'b1) state<=READ_CUT;
                else wr_index<=wr_index+1'b1;
            end
            READ_CUT: state<=GOT_CUT;
            GOT_CUT: begin
                cut_data<=read_data; noise_sum<=0; ref_index<=0;
                if (!eligible) begin
                    m_valid<=1; m_error<=0; m_last<=(cut_index==length-1'b1);
                    m_tag<=tag; m_index<=cut32; m_sample<=read_data;
                    m_noise_sum<=0; m_eligible<=0; m_detect<=0; state<=HOLD;
                end else state<=READ_REF;
            end
            READ_REF: state<=GOT_REF;
            GOT_REF: begin
                noise_sum<=next_sum;
                if (ref_index==2*TRAINING-1) state<=MUL;
                else begin ref_index<=ref_index+1'b1; state<=READ_REF; end
            end
            MUL: begin
                cut_times_den<=cut_data*alpha_den;
                noise_times_num<=noise_sum*alpha_num;
                state<=COMPARE;
            end
            COMPARE: begin
                m_valid<=1; m_error<=0; m_last<=(cut_index==length-1'b1);
                m_tag<=tag; m_index<=cut32; m_sample<=cut_data;
                m_noise_sum<=noise_sum; m_eligible<=1;
                m_detect<=(scaled_cut>noise_times_num); state<=HOLD;
            end
            HOLD: if (m_valid && m_ready) begin
                m_valid<=0;
                if (m_last) state<=IDLE;
                else begin cut_index<=cut_index+1'b1; state<=READ_CUT; end
            end
            default: state<=IDLE;
        endcase
    end
endmodule
