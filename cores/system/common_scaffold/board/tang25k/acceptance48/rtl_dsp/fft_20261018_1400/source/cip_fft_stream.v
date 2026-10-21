// Functional FFT adapter: op 0 forward / 1 inverse, both params zero.
// 16-bit words: input re,im pairs; output re_lo,re_hi,im_lo,im_hi.
module cip_fft_stream #(parameter DATA_W=16, parameter TAG_W=8, parameter LOG_N=6)(
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
    output reg [DATA_W-1:0] m_data,
    output wire m_valid,
    input wire m_ready
);
localparam N=1<<LOG_N,OUT_W=16+LOG_N+2;
localparam IDLE=0,GET_RE=1,GET_IM=2,WAIT_RESULT=3,SEND=4;
reg [2:0] state;
reg [1:0] word_index;
reg [LOG_N-1:0] input_index;
reg [TAG_W-1:0] run_tag;
reg signed [15:0] input_re;
reg inverse,abort_core;
wire core_ready,core_valid,core_last,core_error;
wire signed [OUT_W-1:0] result_re,result_im;
wire bad_end=s_last!=(input_index==N-1);
wire core_rst_n=rst_n && !abort_core;
assign cmd_ready=rst_n && state==IDLE && !rsp_valid && !abort_core;
assign s_ready=rst_n && (state==GET_RE || (state==GET_IM && core_ready));
assign m_valid=rst_n && state==SEND && core_valid && !core_error;
assign m_last=m_valid && word_index==3 && core_last;
always @* begin
    case(word_index)
        0:m_data=result_re[15:0];
        1:m_data=result_re>>>16;
        2:m_data=result_im[15:0];
        default:m_data=result_im>>>16;
    endcase
end
cip_dsp_fft #(.DATA_W(16),.LOG_N(LOG_N)) core(
    .clk(clk),.rst_n(core_rst_n),.clk_en(clk_en),
    .s_valid(state==GET_IM && s_valid && !bad_end),.s_ready(core_ready),
    .s_inverse(inverse),.s_last(s_last),.s_re(input_re),.s_im(s_data),
    .m_valid(core_valid),.m_ready(state==SEND && word_index==3 && m_ready),
    .m_last(core_last),.m_error(core_error),.m_re(result_re),.m_im(result_im));
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;word_index<=0;input_index<=0;run_tag<=0;input_re<=0;
        inverse<=0;abort_core<=0;rsp_valid<=0;rsp_tag<=0;rsp_error<=0;
    end else if(clk_en) begin
        abort_core<=0;
        if(rsp_valid && rsp_ready) rsp_valid<=0;
        case(state)
        IDLE:if(cmd_valid && cmd_ready) begin
            rsp_tag<=cmd_tag;
            if(cfg_opcode>1) begin rsp_valid<=1;rsp_error<=1;end
            else if(DATA_W!=16 || cfg_param0!=0 || cfg_param1!=0) begin rsp_valid<=1;rsp_error<=2;end
            else begin state<=GET_RE;input_index<=0;run_tag<=cmd_tag;inverse<=cfg_opcode[0];end
        end
        GET_RE:if(s_valid && s_ready) begin
            if(s_last) begin
                abort_core<=1;state<=IDLE;rsp_valid<=1;rsp_tag<=run_tag;rsp_error<=2;
            end else begin input_re<=s_data;state<=GET_IM;end
        end
        GET_IM:if(s_valid && s_ready) begin
            if(bad_end) begin
                abort_core<=1;state<=IDLE;rsp_valid<=1;rsp_tag<=run_tag;rsp_error<=2;
            end else if(s_last) state<=WAIT_RESULT;
            else begin input_index<=input_index+1'b1;state<=GET_RE;end
        end
        WAIT_RESULT:if(core_valid) begin
            if(core_error) begin
                abort_core<=1;state<=IDLE;rsp_valid<=1;rsp_tag<=run_tag;rsp_error<=2;
            end else begin state<=SEND;word_index<=0;end
        end
        SEND:if(m_valid && m_ready) begin
            if(word_index==3) begin
                if(core_last) begin state<=IDLE;rsp_valid<=1;rsp_tag<=run_tag;rsp_error<=0;end
                else state<=WAIT_RESULT;
            end else word_index<=word_index+1'b1;
        end
        default:state<=IDLE;
        endcase
    end
end
endmodule
