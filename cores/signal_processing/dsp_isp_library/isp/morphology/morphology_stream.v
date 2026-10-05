// Frame-atomic erosion/dilation/opening/closing with programmable support mask.
module morphology_stream #(parameter BITS=8,WIDTH=32,HEIGHT=24,K=3,PAD_MODE=0)(
 input wire clk,rst_n,
 input wire [BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,output wire s_tready,
 output wire [BITS-1:0] m_tdata,
 output wire m_tvalid,m_tuser,m_tlast,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [1:0] cfg_op,input wire cfg_binary,input wire [K*K-1:0] cfg_mask,
 output reg cfg_done,cfg_error,output wire marker_error,output reg busy
);
 localparam CW=$clog2(WIDTH*HEIGHT+1);
 reg [1:0] op;
 reg binary_mode;
 reg [K*K-1:0] mask;
 wire [K*K-1:0] reflected_mask;
 genvar mi;
 generate for(mi=0;mi<K*K;mi=mi+1)begin: reflect
   assign reflected_mask[mi]=mask[K*K-1-mi];
 end endgenerate
 reg [CW-1:0] ins,outs;
 wire paired=op[1];
 assign cfg_ready=rst_n && !busy;
 wire allow_input=rst_n && (ins<WIDTH*HEIGHT) && !(cfg_valid && cfg_ready);
 wire wr1,wv1,wu1,wl1,we1;
 wire [K*K*BITS-1:0] wd1,wd2;
 wire [BITS-1:0] rd1,rd2;
 wire rr1,rv1,ru1,rl1,wr2,wv2,wu2,wl2,we2,rr2,rv2,ru2,rl2;
 wire [BITS-1:0] normalized=binary_mode?{{(BITS-1){1'b0}},(s_tdata!={BITS{1'b0}})}:s_tdata;
 assign s_tready=allow_input && wr1;
 stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.K(K),.PAD_MODE(PAD_MODE)) win1(
   .clk(clk),.rst_n(rst_n),.s_tdata(normalized),.s_tvalid(s_tvalid&&allow_input),.s_tuser(s_tuser),.s_tlast(s_tlast),.s_tready(wr1),
   .m_tdata(wd1),.m_tvalid(wv1),.m_tuser(wu1),.m_tlast(wl1),.m_tready(rr1),.marker_error(we1));
 morph_reduce #(.BITS(BITS),.K(K)) reduce1(clk,rst_n,wd1,wv1,wu1,wl1,rr1,op[0]?reflected_mask:mask,op[0],rd1,rv1,ru1,rl1,paired?wr2:m_tready);
 stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.K(K),.PAD_MODE(PAD_MODE)) win2(
   .clk(clk),.rst_n(rst_n),.s_tdata(rd1),.s_tvalid(rv1&&paired),.s_tuser(ru1),.s_tlast(rl1),.s_tready(wr2),
   .m_tdata(wd2),.m_tvalid(wv2),.m_tuser(wu2),.m_tlast(wl2),.m_tready(rr2),.marker_error(we2));
 morph_reduce #(.BITS(BITS),.K(K)) reduce2(clk,rst_n,wd2,wv2,wu2,wl2,rr2,op[0]?mask:reflected_mask,!op[0],rd2,rv2,ru2,rl2,m_tready&&paired);
 assign m_tdata=paired?rd2:rd1;
 assign m_tvalid=paired?rv2:rv1;
 assign m_tuser=paired?ru2:ru1;
 assign m_tlast=paired?rl2:rl1;
 assign marker_error=we1||we2;
 always @(posedge clk)begin
   if(!rst_n)begin
     op<=0;binary_mode<=0;mask<={K*K{1'b1}};ins<=0;outs<=0;busy<=0;cfg_done<=0;cfg_error<=0;
   end else begin
     cfg_done<=0;cfg_error<=0;
     if(cfg_valid && cfg_ready)begin
       if(cfg_mask==0)cfg_error<=1;
       else begin op<=cfg_op;binary_mode<=cfg_binary;mask<=cfg_mask;cfg_done<=1;end
     end
     if(s_tvalid && s_tready)begin ins<=ins+1'b1;busy<=1;end
     if(m_tvalid && m_tready)begin
       if(outs==WIDTH*HEIGHT-1)begin outs<=0;ins<=0;busy<=0;end
       else outs<=outs+1'b1;
     end
   end
 end
 initial begin
   if((BITS!=8 && BITS!=10) || WIDTH<1 || HEIGHT<1 || (K!=3 && K!=5) || (PAD_MODE!=0 && PAD_MODE!=1))
     $fatal(1,"unsupported morphology parameters");
 end
endmodule
