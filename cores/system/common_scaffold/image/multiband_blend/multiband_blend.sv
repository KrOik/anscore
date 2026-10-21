// Three Gaussian pyramids, Laplacian mask blend, serial coarse-to-fine reconstruction.
module multiband_blend(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,input wire [5:0] cfg_width,cfg_height,
 input wire [1:0] cfg_levels,output reg cfg_done,cfg_error,
 input wire start_valid,output wire start_ready,
 input wire [7:0] s_a,s_b,s_mask,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output reg [7:0] m_data,output reg m_valid,m_sof,m_eol,m_last,input wire m_ready,
 output reg done_valid,input wire done_ready,output reg [3:0] error_code,output wire busy
);
 localparam IDLE=0,CAP=1,BUILD=2,BUILDRET=3,COARSE=4,CR=5,CV=6,COARSERET=7,
  FINE=8,FR=9,FV=10,UPA=11,UPB=12,UPR=13,UPDONE=14,FINERET=15,
  OUTADDR=16,OUTREAD=17,OUTVAL=18,OUTPUT=19,DONE=20,
  FILTER=21,TAPADDR=22,TAPREAD=23,TAPVAL=24,TAPNEXT=25,
  BMUL=26,BDIV=27,BSAVE=28;
 reg [4:0] state,filter_return,blend_return;
 reg configured;
 reg [5:0] widths[0:2],heights[0:2];
 reg [1:0] levels,level,channel,filter_level,filter_channel;
 reg [5:0] px,py;
 reg [15:0] ga[0:1343],gb[0:1343],gm[0:1343],aq,bq,mq;
 reg signed [19:0] reconstruction[0:1343],rq;
 reg [10:0] read_addr;
 reg [2:0] tx,ty;
 reg down;
 reg signed [31:0] filter_acc;
 reg signed [19:0] filter_result,fine_a,fine_b,up_a,up_b,up_r,blend_base,blend_result;
 reg [15:0] fine_mask;
 reg [35:0] product,shifted;
 reg [15:0] multiplier;
 reg negative;
 reg [5:0] bit_index;
 reg [35:0] quotient;
 reg [16:0] remainder;
 wire [35:0] product_next=product+(multiplier[0]?shifted:36'd0);
 wire [16:0] trial={remainder[15:0],quotient[35]};
 wire take=trial>=17'd65280;
 wire [35:0] quotient_next={quotient[34:0],take};
 wire signed [36:0] blend_signed=negative?-$signed({1'b0,quotient_next}):$signed({1'b0,quotient_next});
 function [10:0] base;
 input[1:0] l;
 begin case(l)0:base=0;1:base=1024;default:base=1280;endcase end endfunction
 wire [10:0] pixel_address=base(level)+py*widths[level]+px;
 wire signed [8:0] ix=down?$signed({2'b00,px,1'b0})+$signed({6'd0,tx})-9'sd2:$signed({3'd0,px})+$signed({6'd0,tx})-9'sd2;
 wire signed [8:0] iy=down?$signed({2'b00,py,1'b0})+$signed({6'd0,ty})-9'sd2:$signed({3'd0,py})+$signed({6'd0,ty})-9'sd2;
 wire signed [8:0] sx=down?ix:(ix>>>1),sy=down?iy:(iy>>>1);
 function [5:0] border;
 input signed[8:0] index;input[5:0] size;input is_down;
 reg signed[8:0] z,limit;integer t;
 begin
  z=index;limit=$signed({3'd0,size});
  if(size==1)z=0;
  else if(is_down)begin
   for(t=0;t<3;t=t+1)begin if(z<0)z=-z;else if(z>=limit)z=(limit<<<1)-2-z;end
  end else begin if(z<0)z=-z;if(z>=limit)z=limit-1;end
  border=z[5:0];
 end endfunction
 function [2:0] weight;
 input[2:0] n;
 begin case(n)0,4:weight=1;1,3:weight=4;default:weight=6;endcase end endfunction
 wire [5:0] bx=border(sx,widths[filter_level],down),by=border(sy,heights[filter_level],down);
 wire [5:0] factor=weight(tx)*weight(ty);
 wire skip=!down&&(ix[0]||iy[0]);
 wire signed[19:0] sample=filter_channel==0?$signed({4'd0,aq}):
  filter_channel==1?$signed({4'd0,bq}):filter_channel==2?$signed({4'd0,mq}):rq;
 reg signed[31:0] weighted;
 always @*case(factor)
  1:weighted=$signed(sample);4:weighted=$signed(sample)*32'sd4;6:weighted=$signed(sample)*32'sd6;
  16:weighted=$signed(sample)*32'sd16;24:weighted=$signed(sample)*32'sd24;36:weighted=$signed(sample)*32'sd36;
  default:weighted=0;
 endcase
 wire signed[31:0] rounded=down?(filter_acc+32'sd128)>>>8:(filter_acc+32'sd32)>>>6;
 wire signed[20:0] recon_sum=$signed(blend_base)+$signed(blend_signed);
 wire signed[20:0] output_rounded=($signed(rq)+21'sd128)>>>8;
 assign cfg_ready=rst_n&&ce&&state==IDLE;
 assign start_ready=cfg_ready&&configured&&!cfg_valid;
 assign s_ready=rst_n&&ce&&state==CAP;
 assign busy=state!=IDLE&&state!=DONE;
 task filter;
 input is_down;input[1:0] source_level,source_channel;input[4:0] target;
 begin down<=is_down;filter_level<=source_level;filter_channel<=source_channel;
  filter_return<=target;filter_acc<=0;tx<=0;ty<=0;state<=TAPADDR;end endtask
 task blend;
 input signed[19:0] difference,baseline;input[15:0] mask;input[4:0] target;
 begin product<=0;shifted<={16'd0,(difference<0?-$unsigned(difference):$unsigned(difference))};
  multiplier<=mask;negative<=difference[19];blend_base<=baseline;blend_return<=target;bit_index<=0;state<=BMUL;
 end endtask
 always @(posedge clk)if(ce)begin aq<=ga[read_addr];bq<=gb[read_addr];mq<=gm[read_addr];rq<=reconstruction[read_addr];end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;configured<=0;cfg_done<=0;cfg_error<=0;done_valid<=0;error_code<=0;
   m_valid<=0;m_data<=0;m_sof<=0;m_eol<=0;m_last<=0;px<=0;py<=0;level<=0;read_addr<=0;
   widths[0]<=1;widths[1]<=1;widths[2]<=1;heights[0]<=1;heights[1]<=1;heights[2]<=1;levels<=2;
  end else if(ce)begin
   cfg_done<=0;cfg_error<=0;
   case(state)
    IDLE:if(cfg_valid)begin
     if(cfg_width==0||cfg_width>32||cfg_height==0||cfg_height>32||(cfg_levels!=2&&cfg_levels!=3))cfg_error<=1;
     else begin
      widths[0]<=cfg_width;heights[0]<=cfg_height;
      widths[1]<=({1'b0,cfg_width}+1)>>1;heights[1]<=({1'b0,cfg_height}+1)>>1;
      widths[2]<=({1'b0,cfg_width}+3)>>2;heights[2]<=({1'b0,cfg_height}+3)>>2;
      levels<=cfg_levels;configured<=1;cfg_done<=1;
     end
    end else if(start_valid&&start_ready)begin px<=0;py<=0;level<=0;error_code<=0;state<=CAP;end
    CAP:if(s_valid)begin
     if(s_sof!=(px==0&&py==0)||s_eol!=(px==widths[0]-1)||s_last!=(px==widths[0]-1&&py==heights[0]-1))begin
      error_code<=1;done_valid<=1;state<=DONE;
     end else begin
      ga[pixel_address]<={s_a,8'd0};gb[pixel_address]<={s_b,8'd0};gm[pixel_address]<={s_mask,8'd0};
      if(px==widths[0]-1)begin px<=0;if(py==heights[0]-1)begin py<=0;level<=1;channel<=0;state<=BUILD;end else py<=py+1'b1;end
      else px<=px+1'b1;
     end
    end
    BUILD:filter(1,level-1'b1,channel,BUILDRET);
    BUILDRET:begin
     case(channel)0:ga[pixel_address]<=filter_result[15:0];1:gb[pixel_address]<=filter_result[15:0];2:gm[pixel_address]<=filter_result[15:0];endcase
     if(px==widths[level]-1)begin px<=0;if(py==heights[level]-1)begin py<=0;
      if(channel==2)begin channel<=0;if(level==levels-1)state<=COARSE;else begin level<=level+1'b1;state<=BUILD;end end
      else begin channel<=channel+1'b1;state<=BUILD;end
     end else begin py<=py+1'b1;state<=BUILD;end end else begin px<=px+1'b1;state<=BUILD;end
    end
    COARSE:begin read_addr<=pixel_address;state<=CR;end
    CR:state<=CV;
    CV:blend($signed({4'd0,aq})-$signed({4'd0,bq}),$signed({4'd0,bq}),mq,COARSERET);
    COARSERET:begin
     reconstruction[pixel_address]<=blend_result;
     if(px==widths[level]-1)begin px<=0;if(py==heights[level]-1)begin py<=0;level<=level-1'b1;state<=FINE;end else begin py<=py+1'b1;state<=COARSE;end end
     else begin px<=px+1'b1;state<=COARSE;end
    end
    FINE:begin read_addr<=pixel_address;state<=FR;end
    FR:state<=FV;
    FV:begin fine_a<=$signed({4'd0,aq});fine_b<=$signed({4'd0,bq});fine_mask<=mq;filter(0,level+1'b1,0,UPA);end
    UPA:begin up_a<=filter_result;filter(0,level+1'b1,1,UPB);end
    UPB:begin up_b<=filter_result;filter(0,level+1'b1,3,UPR);end
    UPR:begin up_r<=filter_result;state<=UPDONE;end
    UPDONE:blend((fine_a-up_a)-(fine_b-up_b),(fine_b-up_b)+up_r,fine_mask,FINERET);
    FINERET:begin
     reconstruction[pixel_address]<=blend_result;
     if(px==widths[level]-1)begin px<=0;if(py==heights[level]-1)begin py<=0;
      if(level==0)state<=OUTADDR;else begin level<=level-1'b1;state<=FINE;end
     end else begin py<=py+1'b1;state<=FINE;end end else begin px<=px+1'b1;state<=FINE;end
    end
    TAPADDR:if(skip)state<=TAPNEXT;
     else begin read_addr<=base(filter_level)+by*widths[filter_level]+bx;state<=TAPREAD;end
    TAPREAD:state<=TAPVAL;
    TAPVAL:begin filter_acc<=filter_acc+weighted;state<=TAPNEXT;end
    TAPNEXT:if(tx==4)begin tx<=0;if(ty==4)state<=FILTER;else begin ty<=ty+1'b1;state<=TAPADDR;end end
     else begin tx<=tx+1'b1;state<=TAPADDR;end
    FILTER:begin filter_result<=rounded[19:0];state<=filter_return;end
    BMUL:begin
     product<=product_next;shifted<=shifted<<1;multiplier<=multiplier>>1;
     if(bit_index==15)begin quotient<=product_next+36'd32640;remainder<=0;bit_index<=0;state<=BDIV;end else bit_index<=bit_index+1'b1;
    end
    BDIV:begin
     quotient<=quotient_next;remainder<=take?trial-17'd65280:trial;
     if(bit_index==35)begin
      if(recon_sum>21'sd524287||recon_sum< -21'sd524288)begin error_code<=2;done_valid<=1;state<=DONE;end
      else begin blend_result<=recon_sum[19:0];state<=BSAVE;end
     end else bit_index<=bit_index+1'b1;
    end
    BSAVE:state<=blend_return;
    OUTADDR:begin read_addr<=pixel_address;state<=OUTREAD;end
    OUTREAD:state<=OUTVAL;
    OUTVAL:begin
     m_data<=output_rounded<0?8'd0:output_rounded>255?8'd255:output_rounded[7:0];
     m_sof<=px==0&&py==0;m_eol<=px==widths[0]-1;m_last<=px==widths[0]-1&&py==heights[0]-1;m_valid<=1;state<=OUTPUT;
    end
    OUTPUT:if(m_ready)begin
     m_valid<=0;if(m_last)begin done_valid<=1;state<=DONE;end
     else if(px==widths[0]-1)begin px<=0;py<=py+1'b1;state<=OUTADDR;end else begin px<=px+1'b1;state<=OUTADDR;end
    end
    DONE:if(done_ready)begin done_valid<=0;state<=IDLE;end
    default:begin error_code<=3;m_valid<=0;done_valid<=1;state<=DONE;end
   endcase
  end
 end
endmodule
