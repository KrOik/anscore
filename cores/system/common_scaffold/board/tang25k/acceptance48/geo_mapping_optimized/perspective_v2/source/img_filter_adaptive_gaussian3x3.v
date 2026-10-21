// Exact Gaussian-weighted adaptive binary threshold, weights [1 2 1]^T*[1 2 1]/16.
// selected = center > weighted_mean - signed cfg_offset, then optional inversion.
module img_filter_adaptive_gaussian3x3 #(parameter PIXEL_W=8)(
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
localparam SUM_W=PIXEL_W+4,COMP_W=PIXEL_W+6;
wire [SUM_W-1:0] p[0:8];
genvar i;
generate for(i=0;i<9;i=i+1) begin:extend_taps
    assign p[i]={{4{1'b0}},s_taps[i*PIXEL_W+:PIXEL_W]};
end endgenerate
wire [SUM_W-1:0] corners=(p[0]+p[2])+(p[6]+p[8]);
wire [SUM_W-1:0] edges=((p[1]+p[3])+(p[5]+p[7]))<<1;
wire [SUM_W-1:0] weighted=corners+edges+(p[4]<<2);
wire signed [COMP_W-1:0] sum_ext={2'b0,weighted};
wire signed [COMP_W-1:0] center={{6{1'b0}},s_taps[4*PIXEL_W+:PIXEL_W]};
wire signed [COMP_W-1:0] offset={{5{cfg_offset[PIXEL_W]}},cfg_offset};
wire signed [COMP_W-1:0] center16=center<<<4;
wire signed [COMP_W-1:0] threshold16=sum_ext-(offset<<<4);
wire selected=(center16>threshold16)^cfg_invert;
img_filter_stream_register #(.DATA_W(PIXEL_W),.PIPE_STAGES(3)) output_register(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data({PIXEL_W{selected}}),.s_valid(s_valid),.s_ready(s_ready),
    .s_sof(s_sof),.s_eol(s_eol),.m_data(m_data),.m_valid(m_valid),
    .m_sof(m_sof),.m_eol(m_eol),.m_ready(m_ready));
`ifndef SYNTHESIS
initial if(PIXEL_W<1 || PIXEL_W>16) $fatal(1,"adaptive Gaussian supports PIXEL_W=1..16");
`endif
endmodule
