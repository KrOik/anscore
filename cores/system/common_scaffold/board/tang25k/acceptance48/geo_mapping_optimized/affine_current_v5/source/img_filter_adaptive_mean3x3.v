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
// Five actual arithmetic stages. All registers freeze on CE or output stall.
reg [SUM_W-1:0] a0,b0,c0,sum1,remainder1,sum2;
reg [PIXEL_W-1:0] center0;
reg signed [PIXEL_W:0] offset0;
reg signed [COMP_W-1:0] center1,offset1,center2,offset2,center3,threshold3;
reg [4:0] valid,sof,eol,inv;
reg [PIXEL_W-1:0] result;
wire advance=!valid[4] || m_ready;
assign s_ready=rst_n && clk_en && advance;
assign m_valid=valid[4];assign m_sof=sof[4];assign m_eol=eol[4];assign m_data=result;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  valid<=0;sof<=0;eol<=0;inv<=0;a0<=0;b0<=0;c0<=0;sum1<=0;
  center0<=0;offset0<=0;center1<=0;offset1<=0;center2<=0;offset2<=0;center3<=0;threshold3<=0;remainder1<=0;sum2<=0;result<=0;
 end else if(clk_en && advance)begin
  valid<={valid[3:0],s_valid};sof<={sof[3:0],s_sof};eol<={eol[3:0],s_eol};inv<={inv[3:0],cfg_invert};
  if(s_valid)begin
   a0<=p[0]+p[1]+p[2];b0<=p[3]+p[4]+p[5];c0<=p[6]+p[7]+p[8];
   center0<=s_taps[4*PIXEL_W+:PIXEL_W];offset0<=cfg_offset;
  end
  if(valid[0])begin sum1<=a0+b0;remainder1<=c0;center1<=($signed({1'b0,center0})<<<3)+$signed({1'b0,center0});offset1<=($signed(offset0)<<<3)+$signed(offset0); end
  if(valid[1])begin sum2<=sum1+remainder1;center2<=center1;offset2<=offset1;end
  if(valid[2])begin center3<=center2;threshold3<=$signed({2'b0,sum2})-offset2;end
  if(valid[3])result<={PIXEL_W{(center3>threshold3)^inv[3]}};
 end
end
`ifndef SYNTHESIS
initial if(PIXEL_W<1 || PIXEL_W>16) $fatal(1,"adaptive mean supports PIXEL_W=1..16");
`endif
endmodule
