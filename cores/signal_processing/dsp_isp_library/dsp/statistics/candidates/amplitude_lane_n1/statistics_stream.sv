// DIAGNOSTIC ONLY: N=1. RMS lane receives amplitude; no root arithmetic.
// All log2 != 0 configurations are rejected by this isolated core.
// Signed real Q1.15 statistics. Local arithmetic helpers are extractable.
module statistics_stream #(
 parameter integer LOGIC_SQUARE = 0
) (
 input wire clk, rst_n,
 input wire signed [15:0] s_tdata, input wire s_tvalid, output wire s_tready,
 output reg [127:0] m_tdata, output reg [1:0] m_tuser,
 output reg m_tvalid, input wire m_tready,
 input wire cfg_valid, output wire cfg_ready,
 input wire cfg_block, input wire [3:0] cfg_log2,
 input wire signed [4:0] cfg_scale, input wire [31:0] cfg_threshold,
 output reg cfg_done, cfg_error
);
 reg block_mode; reg [3:0] lg; reg signed [4:0] scale;
 reg [31:0] threshold, sample_index, block_position;
 reg [6:0] count;
 reg [36:0] power_sum;
 reg [21:0] abs_sum;
 reg [15:0] block_peak;
 reg block_clip;
 reg [15:0] history[0:63]; reg history_clip[0:63];
 wire [6:0] length=7'd1 << lg;
 assign cfg_ready=rst_n && !m_tvalid;
 assign s_tready=rst_n && !cfg_valid && (!m_tvalid || m_tready);
 wire accept=s_tvalid && s_tready;
 function [36:0] mean_rne;
  input [36:0] a; input [3:0] shift;
  reg [36:0] q,r,h;
  begin
   q=a>>shift; r=a & ((37'd1<<shift)-1); h=0;
   if(shift!=0) begin
    h=37'd1<<(shift-1);
    if(r>h || (r==h && q[0])) q=q+1'b1;
   end
   mean_rne=q;
  end
 endfunction
 // Explicit unsigned square partial products; balanced reduction limits depth.
 // No multiply operator in this path, so it cannot consume a Gowin multiplier.
 function [31:0] square_logic;
  input [15:0] value;
  reg [31:0] sums[1:31];
  integer k;
  begin
   for(k=0;k<16;k=k+1) sums[16+k]=value[k] ? ({16'd0,value}<<k) : 32'd0;
   for(k=15;k>0;k=k-1) sums[k]=sums[2*k]+sums[2*k+1];
   square_logic=sums[1];
  end
 endfunction
 reg [31:0] magnitude, quantized, remscale, halfscale;
 reg signed [32:0] scaled;
 reg clipped;
 reg [15:0] amplitude, old_abs;
 reg [31:0] new_square,old_square;
 reg [36:0] next_power,mean_power_w;
 reg [21:0] next_abs;
 reg [36:0] mean_abs_w;
 reg [15:0] peak;
 reg [31:0] position;
 reg window_clip;
 // Balanced maximum tree. Equal amplitudes choose the older (right) leaf.
 reg [15:0] tree_mag[1:127]; reg [5:0] tree_offset[1:127];
 reg tree_valid[1:127];
 integer i;
 always @* begin
  magnitude=s_tdata[15] ? -$signed({{16{s_tdata[15]}},s_tdata}) : {16'd0,s_tdata};
  quantized=magnitude; remscale=0; halfscale=0;
  if(scale>=0) begin
   quantized=magnitude>>scale;
   if(scale!=0) begin
    remscale=magnitude&((32'd1<<scale)-1); halfscale=32'd1<<(scale-1);
    if(remscale>halfscale || (remscale==halfscale && quantized[0])) quantized=quantized+1;
   end
  end else quantized=magnitude<<(-scale);
  scaled=s_tdata[15] ? -$signed({1'b0,quantized}) : $signed({1'b0,quantized});
  clipped=0;
  if(scaled>32767) begin scaled=32767; clipped=1; end
  else if(scaled < -32768) begin scaled=-32768; clipped=1; end
  amplitude=scaled<0 ? -scaled : scaled;
  old_abs=0;
  if(!block_mode && count>=length) old_abs=history[length-1];
  if(LOGIC_SQUARE) begin
   new_square=square_logic(amplitude);
   old_square=square_logic(old_abs);
  end else begin
   new_square=amplitude*amplitude;
   old_square=old_abs*old_abs;
  end
  next_power=power_sum+{5'd0,new_square}-{5'd0,old_square};
  next_abs=abs_sum+{6'd0,amplitude}-{6'd0,old_abs};
  mean_power_w=mean_rne(next_power,lg);
  mean_abs_w=mean_rne({15'd0,next_abs},lg);
  window_clip=clipped;
  for(i=0;i<64;i=i+1) begin
   tree_mag[64+i]=0; tree_offset[64+i]=i; tree_valid[64+i]=0;
   if(i==0) begin tree_mag[64+i]=amplitude; tree_valid[64+i]=1; end
   else if(i<length && count>=i) begin
    tree_mag[64+i]=history[i-1]; tree_valid[64+i]=1;
    window_clip=window_clip | history_clip[i-1];
   end
  end
  for(i=63;i>0;i=i-1) begin
   if(tree_valid[2*i+1] && (!tree_valid[2*i] || tree_mag[2*i+1]>=tree_mag[2*i])) begin
    tree_mag[i]=tree_mag[2*i+1]; tree_offset[i]=tree_offset[2*i+1]; tree_valid[i]=1;
   end else begin
    tree_mag[i]=tree_mag[2*i]; tree_offset[i]=tree_offset[2*i]; tree_valid[i]=tree_valid[2*i];
   end
  end
  peak=tree_mag[1]; position=sample_index-{26'd0,tree_offset[1]};
  if(block_mode) begin
   window_clip=block_clip|clipped;
   if(count==0 || amplitude>block_peak) begin peak=amplitude; position=sample_index; end
   else begin peak=block_peak; position=block_position; end
  end
 end
 integer j;
 always @(posedge clk) begin
  if(!rst_n) begin
   block_mode<=0; lg<=4; scale<=0; threshold<=32'h10000000;
   count<=0; sample_index<=0; power_sum<=0; abs_sum<=0;
   block_peak<=0; block_position<=0; block_clip<=0;
   m_tvalid<=0; m_tdata<=0; m_tuser<=0; cfg_done<=0; cfg_error<=0;
  end else begin
   cfg_done<=0; cfg_error<=0;
   if(m_tready) m_tvalid<=0;
   if(cfg_valid && cfg_ready) begin
    cfg_done<=1;
    if(cfg_log2!=0 || cfg_scale < -8) cfg_error<=1;
    else begin
     block_mode<=cfg_block; lg<=cfg_log2; scale<=cfg_scale; threshold<=cfg_threshold;
     count<=0; sample_index<=0; power_sum<=0; abs_sum<=0;
     block_peak<=0; block_position<=0; block_clip<=0;
    end
   end
   if(accept) begin
    sample_index<=sample_index+1'b1;
    history[0]<=amplitude; history_clip[0]<=clipped;
    for(j=1;j<64;j=j+1) begin history[j]<=history[j-1]; history_clip[j]<=history_clip[j-1]; end
    power_sum<=next_power; abs_sum<=next_abs;
    block_peak<=peak; block_position<=position; block_clip<=window_clip;
    if(!block_mode || count==length-1) begin
     m_tvalid<=1;
     m_tdata<={position,mean_power_w[31:0],mean_abs_w[15:0],amplitude,peak,amplitude};
     m_tuser<={(mean_power_w[31:0]>=threshold),window_clip};
    end
    if(block_mode && count==length-1) begin
     count<=0; power_sum<=0; abs_sum<=0; block_clip<=0;
    end else if(count<length) count<=count+1'b1;
   end
  end
 end
endmodule
