// Local adaptive binary threshold: center > exact(window mean) - cfg_offset.
// Offset is signed; strict comparison precedes optional inversion. No division.
// External row-major 3x3 taps, top-left in least-significant PIXEL_W bits.
module img_filter_adaptive_mean3x3 #(parameter PIXEL_W=8)(
    input wire clk,rst_n,clk_en,
    input wire [9*PIXEL_W-1:0] s_taps,
    input wire signed [PIXEL_W:0] cfg_offset,
    input wire cfg_invert,
    input wire s_valid,s_sof,s_eol,
    output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_valid,m_sof,m_eol,
    input wire m_ready
);
localparam SUM_W=PIXEL_W+4, COMP_W=PIXEL_W+6;
wire [SUM_W-1:0] p[0:8];
genvar i;
generate for(i=0;i<9;i=i+1) begin:extend_taps
    assign p[i]={{4{1'b0}},s_taps[i*PIXEL_W+:PIXEL_W]};
end endgenerate
wire [SUM_W-1:0] a=p[0]+p[1],b=p[2]+p[3],c=p[4]+p[5],d=p[6]+p[7];
wire [SUM_W-1:0] total=(a+b)+(c+d)+p[8];
wire signed [COMP_W-1:0] sum_ext={2'b0,total};
wire signed [COMP_W-1:0] center={{6{1'b0}},s_taps[4*PIXEL_W+:PIXEL_W]};
wire signed [COMP_W-1:0] offset={{5{cfg_offset[PIXEL_W]}},cfg_offset};
wire signed [COMP_W-1:0] center9=(center<<<3)+center;
wire signed [COMP_W-1:0] offset9=(offset<<<3)+offset;
wire signed [COMP_W-1:0] threshold9=sum_ext-offset9;
wire selected=(center9>threshold9)^cfg_invert;
img_filter_stream_register #(.DATA_W(PIXEL_W),.PIPE_STAGES(3)) output_register(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data({PIXEL_W{selected}}),.s_valid(s_valid),.s_ready(s_ready),
    .s_sof(s_sof),.s_eol(s_eol),.m_data(m_data),.m_valid(m_valid),
    .m_sof(m_sof),.m_eol(m_eol),.m_ready(m_ready));
`ifndef SYNTHESIS
initial if(PIXEL_W<1 || PIXEL_W>16) $fatal(1,"adaptive mean supports PIXEL_W=1..16");
`endif
endmodule
