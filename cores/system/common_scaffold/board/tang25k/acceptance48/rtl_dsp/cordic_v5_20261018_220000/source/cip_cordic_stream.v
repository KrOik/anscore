// Functional CORDIC adapter; fixed 16-bit serialized word format.
// op 0 rotation / 1 vectoring; param0=sign-extended Q14 radians, param1=0.
// Input words x,y; output x_lo,x_hi,y_lo,y_hi,z_lo,z_hi, high words sign extended.
module cip_cordic_stream #(parameter DATA_W=16, parameter TAG_W=8)(
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
localparam IDLE=0,GET_X=1,GET_Y=2,WAIT_RESULT=3,SEND=4;
reg [2:0] state,word_index;
reg [TAG_W-1:0] run_tag;
reg signed [15:0] x;
reg signed [17:0] angle;
reg vectoring;
wire signed [17:0] command_angle=cfg_param0[17:0];
wire signed [31:0] extended_angle=command_angle;
wire core_ready,core_valid,core_last;
wire signed [19:0] result_x,result_y;
wire signed [17:0] result_z;
assign cmd_ready=rst_n && state==IDLE && !rsp_valid;
assign s_ready=rst_n && (state==GET_X || (state==GET_Y && core_ready));
assign m_valid=rst_n && state==SEND && core_valid;
assign m_last=m_valid && word_index==5 && core_last;
always @* begin
    case(word_index)
        0:m_data=result_x[15:0];
        1:m_data=result_x>>>16;
        2:m_data=result_y[15:0];
        3:m_data=result_y>>>16;
        4:m_data=result_z[15:0];
        default:m_data=result_z>>>16;
    endcase
end
cip_dsp_cordic core(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_valid(state==GET_Y && s_valid),.s_ready(core_ready),
    .s_vectoring(vectoring),.s_last(s_last),.s_x(x),.s_y(s_data),.s_z(angle),
    .m_valid(core_valid),.m_ready(state==SEND && word_index==5 && m_ready),
    .m_last(core_last),.m_x(result_x),.m_y(result_y),.m_z(result_z));
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;word_index<=0;run_tag<=0;x<=0;angle<=0;vectoring<=0;
        rsp_valid<=0;rsp_tag<=0;rsp_error<=0;
    end else if(clk_en) begin
        if(rsp_valid && rsp_ready) rsp_valid<=0;
        case(state)
        IDLE:if(cmd_valid && cmd_ready) begin
            rsp_tag<=cmd_tag;
            if(cfg_opcode>1) begin rsp_valid<=1;rsp_error<=1;end
            else if(DATA_W!=16 || cfg_param0!=extended_angle || cfg_param1!=0) begin
                rsp_valid<=1;rsp_error<=2;
            end else begin
                state<=GET_X;run_tag<=cmd_tag;angle<=command_angle;vectoring<=cfg_opcode[0];
            end
        end
        GET_X:if(s_valid && s_ready) begin
            if(s_last) begin
                // An odd-word packet cannot form a vector; do not launch core.
                state<=IDLE;rsp_valid<=1;rsp_tag<=run_tag;rsp_error<=2;
            end else begin x<=s_data;state<=GET_Y;end
        end
        GET_Y:if(s_valid && s_ready) state<=WAIT_RESULT;
        WAIT_RESULT:if(core_valid) begin state<=SEND;word_index<=0;end
        SEND:if(m_valid && m_ready) begin
            if(word_index==5) begin
                if(core_last) begin
                    state<=IDLE;rsp_valid<=1;rsp_tag<=run_tag;rsp_error<=0;
                end else state<=GET_X;
            end else word_index<=word_index+1'b1;
        end
        default:state<=IDLE;
        endcase
    end
end
endmodule
