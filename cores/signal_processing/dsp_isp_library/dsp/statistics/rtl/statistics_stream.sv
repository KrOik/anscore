// Signed real Q1.15 statistics. Local arithmetic helpers are extractable.
//
// statistics_stream is the production top: the statistics leaf (all output
// fields except RMS) followed by a 16-stage elastic square-root pipeline,
// one binary restoring iteration per register stage. The previous
// single-cycle combinational 16-iteration floor root was physically
// diagnosed as not settling within one 27 MHz GW2A cycle (deterministic
// wrong low RMS bits on silicon); this folded form is the candidate that
// passed the physical chain test twice (11 cases each). Output latency is
// 17 cycles from the producing input transfer, initiation interval is 1,
// and the result pipe is elastic: input stalls only when all 17 result
// slots are occupied, and config is accepted only when the pipe is empty.
// The numerical contract is unchanged: RMS is still floor(sqrt(mean_power)).
module statistics_stream #(parameter integer LOGIC_SQUARE=0)(
 input wire clk,rst_n,
 input wire signed [15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output wire [127:0] m_tdata,output wire [1:0] m_tuser,
 output wire m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire cfg_block,input wire [3:0] cfg_log2,
 input wire signed [4:0] cfg_scale,input wire [31:0] cfg_threshold,
 output wire cfg_done,cfg_error
);
 wire [127:0] leaf_data;wire [1:0] leaf_user;
 wire leaf_valid,leaf_ready,leaf_input_ready,leaf_cfg_ready;
 reg [15:0] valid;
 wire [15:0] ready;
 reg [33:0] rem_stage[0:15];reg [15:0] root_stage[0:15];
 reg [31:0] rad_stage[0:15];reg [127:0] metadata[0:15];
 reg [1:0] user_stage[0:15];
 assign cfg_ready=rst_n && leaf_cfg_ready && !(|valid);
 assign s_tready=leaf_input_ready && !cfg_valid;
 assign leaf_ready=ready[0];
 statistics_leaf #(.LOGIC_SQUARE(LOGIC_SQUARE)) leaf(
 .clk(clk),.rst_n(rst_n),.s_tdata(s_tdata),
 .s_tvalid(s_tvalid && !cfg_valid),.s_tready(leaf_input_ready),
 .m_tdata(leaf_data),.m_tuser(leaf_user),.m_tvalid(leaf_valid),.m_tready(leaf_ready),
 .cfg_valid(cfg_valid && cfg_ready),.cfg_ready(leaf_cfg_ready),
 .cfg_block(cfg_block),.cfg_log2(cfg_log2),.cfg_scale(cfg_scale),
 .cfg_threshold(cfg_threshold),.cfg_done(cfg_done),.cfg_error(cfg_error));
 // One binary restoring iteration per register: 16 stages.
 function [81:0] root_one;
 input [33:0] prior_rem;input [15:0] prior_root;input [31:0] rad;
 reg [33:0] remainder,trial;reg [15:0] root;reg [31:0] bits_left;
 integer k;
 begin
 remainder=prior_rem;root=prior_root;bits_left=rad;
 for(k=0;k<1;k=k+1) begin
  remainder=(remainder<<2)|{32'b0,bits_left[31:30]};bits_left=bits_left<<2;
  trial=({18'b0,root}<<2)|34'd1;root=root<<1;
  if(remainder>=trial)begin remainder=remainder-trial;root=root|16'd1;end
 end
 root_one={remainder,root,bits_left};
 end
 endfunction
 genvar g;
 generate for(g=0;g<16;g=g+1)begin: stage
 wire incoming_valid;wire [127:0] incoming_data;wire [1:0] incoming_user;
 wire [81:0] calc;
 if(g==0)begin
  assign incoming_valid=leaf_valid;assign incoming_data=leaf_data;assign incoming_user=leaf_user;
  assign calc=root_one(34'b0,16'b0,leaf_data[95:64]);
 end else begin
  assign incoming_valid=valid[g-1];assign incoming_data=metadata[g-1];assign incoming_user=user_stage[g-1];
  assign calc=root_one(rem_stage[g-1],root_stage[g-1],rad_stage[g-1]);
 end
 if(g==15)assign ready[g]=!valid[g] || m_tready;
 else assign ready[g]=!valid[g] || ready[g+1];
 always @(posedge clk)begin
  if(!rst_n)valid[g]<=0;
  else if(ready[g])begin
   valid[g]<=incoming_valid;
   if(incoming_valid)begin
    {rem_stage[g],root_stage[g],rad_stage[g]}<=calc;
    metadata[g]<=incoming_data;user_stage[g]<=incoming_user;
   end
  end
 end
 end endgenerate
 assign m_tvalid=valid[15];assign m_tuser=user_stage[15];
 assign m_tdata={metadata[15][127:48],root_stage[15],metadata[15][31:0]};
endmodule

// Statistics leaf: identical algorithm to the original monolithic core,
// but the RMS field is emitted as zero; the raw 32-bit rounded mean power
// stays in m_tdata[95:64] for the external root pipeline to consume.
module statistics_leaf #(
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
    if(cfg_log2>6 || cfg_scale < -8) cfg_error<=1;
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
     m_tdata<={position,mean_power_w[31:0],mean_abs_w[15:0],16'b0,peak,amplitude};
     m_tuser<={(mean_power_w[31:0]>=threshold),window_clip};
    end
    if(block_mode && count==length-1) begin
     count<=0; power_sum<=0; abs_sum<=0; block_clip<=0;
    end else if(count<length) count<=count+1'b1;
   end
  end
 end
endmodule
