// Frame-atomic RGB -> production four-stage CSC gray lane -> full morphology.
module csc_morphology_stream #(parameter BITS=8,WIDTH=8,HEIGHT=8,PAD_MODE=1)(
 input wire clk,rst_n,input wire [3*BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,output wire s_tready,
 output wire [BITS-1:0] m_tdata,output wire m_tvalid,m_tuser,m_tlast,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,input wire [31:0] cfg_word,
 output reg cfg_done,cfg_error,output wire marker_error,output reg busy
);
 localparam CW=$clog2(WIDTH*HEIGHT+1);
 reg [CW-1:0] ins,outs;
 reg configured,config_pending;
 wire ccr,mcr,cer,mer,mcd,mbusy;
 wire legal=(cfg_word[31:14]==0)&&(cfg_word[13:5]!=0);
 // A pending CSC config awaits SOF. Do not feed its combinational commit-ready
 // through the source gate: that creates a ready/valid combinational loop.
 assign cfg_ready=rst_n&&!busy&&!config_pending&&mcr;
 wire configure=cfg_valid&&cfg_ready&&legal;
 wire allow=rst_n&&configured&&(ins<WIDTH*HEIGHT)&&!(cfg_valid&&cfg_ready);
 wire cr,cv,cu,cl,mready;
 wire [3*BITS-1:0] color;
 csc_stream #(.BITS(BITS)) csc(clk,rst_n,s_tdata,s_tvalid&&allow,s_tuser,s_tlast,cr,color,cv,cu,cl,mready,
   configure,ccr,2'd2,cfg_word[0],cfg_word[1],cer);
 assign s_tready=allow&&cr;
 morphology_stream #(.BITS(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.K(3),.PAD_MODE(PAD_MODE)) morph(
   clk,rst_n,color[3*BITS-1:2*BITS],cv,cu,cl,mready,m_tdata,m_tvalid,m_tuser,m_tlast,m_tready,
   configure,mcr,cfg_word[3:2],cfg_word[4],cfg_word[13:5],mcd,mer,marker_error,mbusy);
 always @(posedge clk)begin
   if(!rst_n)begin ins<=0;outs<=0;busy<=0;configured<=0;config_pending<=0;cfg_done<=0;cfg_error<=0;end
   else begin
     cfg_done<=0;cfg_error<=0;
     if(cfg_valid&&cfg_ready)begin if(legal)begin cfg_done<=1;configured<=1;config_pending<=1;end else cfg_error<=1;end
     if(cer||mer)cfg_error<=1;
     if(s_tvalid&&s_tready)begin ins<=ins+1'b1;busy<=1;config_pending<=0;end
     if(m_tvalid&&m_tready)begin
       if(outs==WIDTH*HEIGHT-1)begin ins<=0;outs<=0;busy<=0;end else outs<=outs+1'b1;
     end
   end
 end
endmodule
