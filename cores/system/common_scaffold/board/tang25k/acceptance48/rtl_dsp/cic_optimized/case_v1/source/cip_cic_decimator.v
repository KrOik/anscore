// Functional CIC adapter: opcode 0 RUN with zero parameters; other opcodes unsupported.
// Saturate the full-width CIC result after configurable arithmetic right shift.
module cip_cic_decimator #(parameter DATA_W=16,TAG_W=8,RATE=8,STAGES=3,
    ACC_W=DATA_W+STAGES*$clog2(RATE),SHIFT=STAGES*$clog2(RATE))(
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
wire core_ready,core_valid,core_last;
wire signed [ACC_W-1:0] core_data;
wire signed [ACC_W-1:0] scaled=core_data>>>SHIFT;
localparam signed [ACC_W-1:0] MAXIMUM=({{(ACC_W-1){1'b0}},1'b1}<<(DATA_W-1))-1;
localparam signed [ACC_W-1:0] MINIMUM=-(MAXIMUM+1);
assign cmd_ready=rst_n && !active && !rsp_valid;
assign s_ready=rst_n && active && !input_closed && core_ready;
assign m_valid=rst_n && active && core_valid;
assign m_last=m_valid && core_last;
assign m_data=scaled>MAXIMUM?MAXIMUM[DATA_W-1:0]:
              scaled<MINIMUM?MINIMUM[DATA_W-1:0]:scaled[DATA_W-1:0];
cip_dsp_cic_decimator #(.DATA_W(DATA_W),.RATE(RATE),.STAGES(STAGES),.ACC_W(ACC_W)) core(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
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
                if(cfg_opcode==0) rsp_error<=2'd2;
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
