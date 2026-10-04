// True convolution with a single time-multiplexed signed multiplier.
module convolution_stream #(parameter BITS=8,WIDTH=32,HEIGHT=24,K=3,PAD_MODE=0)(
 input wire clk,rst_n,input wire [BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,output wire s_tready,
 output reg [BITS-1:0] m_tdata,output reg m_tvalid,m_tuser,m_tlast,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,input wire [K*K*12-1:0] cfg_coeff,
 input wire signed [31:0] cfg_bias,input wire [5:0] cfg_shift,
 output reg cfg_done,cfg_error,output wire marker_error,output reg busy
);
 localparam N=K*K,CW=$clog2(WIDTH*HEIGHT+1),TW=$clog2(N);
 localparam SW=BITS+12+$clog2(N),AW=((SW>32)?SW:32)+1;
 reg [N*12-1:0] coeff;
 reg signed [31:0] bias;
 reg [5:0] shift;
 reg [CW-1:0] ins,outs;
 reg running;
 reg [TW-1:0] tap;
 reg [N*BITS-1:0] window;
 reg signed [AW-1:0] accumulator;
 wire [N*BITS-1:0] wd;
 wire wr,wv,wu,wl;
 wire ready_window=!running && (!m_tvalid || m_tready);
 assign cfg_ready=rst_n && !busy;
 wire allow=rst_n && ins<WIDTH*HEIGHT && !(cfg_valid&&cfg_ready);
 assign s_tready=allow && wr;
 stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.K(K),.PAD_MODE(PAD_MODE)) win(
   clk,rst_n,s_tdata,s_tvalid&&allow,s_tuser,s_tlast,wr,wd,wv,wu,wl,ready_window,marker_error);
 wire signed [BITS:0] pixel=$signed({1'b0,window[(N-1-tap)*BITS+:BITS]});
 wire signed [11:0] coefficient=$signed(coeff[tap*12+:12]);
 wire signed [BITS+12:0] product=pixel*coefficient;
 wire signed [AW-1:0] extended_product={{(AW-BITS-13){product[BITS+12]}},product};
 wire signed [AW-1:0] next_sum=accumulator+extended_product;
 function [BITS-1:0] quantize;
   input signed [AW-1:0] value;input [5:0] amount;
   reg [AW:0] magnitude,quotient,remainder,half;
   reg signed [AW:0] rounded;
   begin
     magnitude=value<0?-$signed({value[AW-1],value}):{1'b0,value};
     quotient=magnitude>>amount;
     remainder=magnitude & (({{AW{1'b0}},1'b1}<<amount)-1'b1);
     half=(amount==0)?0:({{AW{1'b0}},1'b1}<<(amount-1'b1));
     if(amount!=0 && (remainder>half || (remainder==half && quotient[0])))quotient=quotient+1'b1;
     rounded=value<0?-$signed(quotient):$signed(quotient);
     if(rounded<0)quantize=0;
     else if(rounded>((1<<BITS)-1))quantize={BITS{1'b1}};
     else quantize=rounded[BITS-1:0];
   end
 endfunction
 integer i;
 always @(posedge clk)begin
   if(!rst_n)begin
     coeff<=0;coeff[(N/2)*12+:12]<=12'd1;bias<=0;shift<=0;
     ins<=0;outs<=0;busy<=0;running<=0;tap<=0;accumulator<=0;
     m_tvalid<=0;m_tuser<=0;m_tlast<=0;cfg_done<=0;cfg_error<=0;
   end else begin
     cfg_done<=0;cfg_error<=0;
     if(m_tready)m_tvalid<=0;
     if(cfg_valid&&cfg_ready)begin
       if(cfg_shift>31)cfg_error<=1;
       else begin coeff<=cfg_coeff;bias<=cfg_bias;shift<=cfg_shift;cfg_done<=1;end
     end
     if(s_tvalid&&s_tready)begin ins<=ins+1'b1;busy<=1;end
     if(wv&&ready_window)begin
       window<=wd;running<=1;tap<=0;accumulator<={{(AW-32){bias[31]}},bias};
       m_tuser<=wu;m_tlast<=wl;
     end
     if(running)begin
       if(tap==N-1)begin m_tdata<=quantize(next_sum,shift);m_tvalid<=1;running<=0;end
       else begin accumulator<=next_sum;tap<=tap+1'b1;end
     end
     if(m_tvalid&&m_tready)begin
       if(outs==WIDTH*HEIGHT-1)begin outs<=0;ins<=0;busy<=0;end
       else outs<=outs+1'b1;
     end
   end
 end
 initial begin
   if((BITS!=8&&BITS!=10) || WIDTH<1 || HEIGHT<1 || (K!=3&&K!=5) || (PAD_MODE!=0&&PAD_MODE!=1))
     $fatal(1,"unsupported convolution parameters");
 end
endmodule
