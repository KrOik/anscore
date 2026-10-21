// Functional legacy-ABI IIR biquad adapter; hand maintained, not generator output.
// opcode 0 RUN: params zero; response follows final output transfer.
// opcode 1 COEFFICIENT: param0=address, param1=sign-extended coefficient.
module cip_iir_biquad_stream #(parameter DATA_W=16,TAG_W=8,COEFF_W=16,SHIFT=14)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [TAG_W-1:0] cmd_tag,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [TAG_W-1:0] rsp_tag,
    output reg [1:0] rsp_error,
    input wire [7:0] cfg_opcode,
    input wire [31:0] cfg_param0, cfg_param1,
    input wire s_last,
    output wire m_last,
    input wire [DATA_W-1:0] s_data,
    input wire s_valid,
    output wire s_ready,
    output wire [DATA_W-1:0] m_data,
    output wire m_valid,
    input wire m_ready
);
reg active,input_closed;
reg [TAG_W-1:0] run_tag;
wire core_ready,core_valid,core_last,coeff_ready;
wire signed [DATA_W-1:0] core_data;
wire signed [COEFF_W-1:0] coeff_value=cfg_param1[COEFF_W-1:0];
wire signed [31:0] extended_coeff=coeff_value;
wire valid_coeff=cfg_param0<5 && cfg_param1==extended_coeff;
wire coefficient_write=cmd_valid && cmd_ready && cfg_opcode==1 && valid_coeff;
assign cmd_ready=rst_n && !active && !rsp_valid;
assign s_ready=rst_n && active && !input_closed && core_ready;
assign m_valid=rst_n && active && core_valid;
assign m_last=m_valid && core_last;
assign m_data=core_data;
cip_dsp_iir_biquad #(.DATA_W(DATA_W),.COEFF_W(COEFF_W),.SHIFT(SHIFT)) core(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .coeff_valid(coefficient_write),.coeff_ready(coeff_ready),
    .coeff_addr(cfg_param0[2:0]),.coeff_data(coeff_value),
    .s_data(s_data),.s_valid(s_valid && active && !input_closed),.s_last(s_last),
    .s_ready(core_ready),.m_data(core_data),.m_valid(core_valid),.m_last(core_last),
    .m_ready(m_ready && active));
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        active<=0;input_closed<=0;run_tag<=0;
        rsp_valid<=0;rsp_tag<=0;rsp_error<=0;
    end else if(clk_en) begin
        if(rsp_valid && rsp_ready) rsp_valid<=0;
        if(cmd_valid && cmd_ready) begin
            rsp_tag<=cmd_tag;
            if(cfg_opcode==0 && cfg_param0==0 && cfg_param1==0) begin
                active<=1;input_closed<=0;run_tag<=cmd_tag;
            end else begin
                rsp_valid<=1;
                if(cfg_opcode==1) rsp_error<=valid_coeff && coeff_ready ? 2'd0 : 2'd2;
                else if(cfg_opcode==0) rsp_error<=2'd2;
                else rsp_error<=2'd1;
            end
        end
        if(s_valid && s_ready && s_last) input_closed<=1;
        if(m_valid && m_ready && core_last) begin
            active<=0;rsp_valid<=1;rsp_tag<=run_tag;rsp_error<=0;
        end
    end
end
endmodule
