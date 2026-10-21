// Four Bayer-plane mesh LSC, exact rational bilinear gain, single RAW rounding.
module lens_shading #(
 parameter WIDTH=33,HEIGHT=25,BITS=12,GRID_WIDTH=3,GRID_HEIGHT=3,
 parameter GAIN_BITS=16,GAIN_FRAC=12
)(input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,input wire[15:0]cfg_index,input wire[GAIN_BITS-1:0]cfg_gain,
 input wire cfg_commit_valid,output wire cfg_commit_ready,output reg cfg_error,output reg cfg_pending,
 input wire start_valid,output wire start_ready,input wire[1:0]cfg_pattern,
 input wire[BITS-1:0]s_data,input wire s_valid,output wire s_ready,input wire s_sof,s_eol,s_last,
 output reg[BITS-1:0]m_data,output reg m_saturated,
 output wire m_valid,input wire m_ready,output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[2:0]error_code
);
 localparam N=WIDTH*HEIGHT,PLANE=GRID_WIDTH*GRID_HEIGHT,ENTRIES=4*PLANE;
 localparam DX=WIDTH>1?WIDTH-1:1,DY=HEIGHT>1?HEIGHT-1:1;
 localparam[63:0]DENOMINATOR=(64'd1*DX*DY)<<GAIN_FRAC,RAW_MAX=(64'd1<<BITS)-1;
 localparam IDLE=0,INPUT=1,READ_GAIN=2,USE_GAIN=3,MUL_STEP=4,WEIGHT_RESULT=5,TERM_RESULT=6,RAW_INIT=7,RAW_RESULT=8,DIV_STEP=9,DIV_ROUND=10,DIV_SAVE=11,HOLD=12,DONE=13;
 reg[3:0]state,return_state;
 reg[GAIN_BITS-1:0]maps[0:2*ENTRIES-1],gain_q,current_gain;
 reg[ENTRIES-1:0]written;
 reg active_bank,configured;reg[1:0]pattern,channel,corner;
 integer pixel,x,y,cell_x,cell_y,rx,ry,step;
 integer sx,sy,ix,iy,fracx,fracy,mesh_x,mesh_y;
 reg[31:0]weight_x,weight_y;
 reg[BITS-1:0]raw;
 reg[63:0]weighted_gain,multiplicand,mul_sum,product,numerator,quotient,rounded;
 reg[31:0]multiplier;reg[64:0]remainder;
 wire[63:0]mul_next=mul_sum+(multiplier[0]?multiplicand:64'd0);
 wire[64:0]shifted_remainder={remainder[63:0],numerator[63]};
 wire capture=s_valid&&s_ready;
 wire[15:0]gain_read_address=(active_bank?ENTRIES:0)+channel*PLANE+mesh_y*GRID_WIDTH+mesh_x;
 reg[1:0]pixel_channel;
 always @*begin
  sx=x*(GRID_WIDTH-1);sy=y*(GRID_HEIGHT-1);
  ix=WIDTH==1?0:sx/DX;iy=HEIGHT==1?0:sy/DY;
  fracx=WIDTH==1?0:sx%DX;fracy=HEIGHT==1?0:sy%DY;
  if(ix==GRID_WIDTH-1)begin ix=GRID_WIDTH-2;fracx=DX;end
  if(iy==GRID_HEIGHT-1)begin iy=GRID_HEIGHT-2;fracy=DY;end
  mesh_x=cell_x+corner[0];mesh_y=cell_y+corner[1];
  weight_x=corner[0]?rx:DX-rx;weight_y=corner[1]?ry:DY-ry;
  case(pattern)
   0:case({y[0],x[0]})0:pixel_channel=0;1:pixel_channel=1;2:pixel_channel=2;default:pixel_channel=3;endcase
   3:case({y[0],x[0]})0:pixel_channel=3;1:pixel_channel=2;2:pixel_channel=1;default:pixel_channel=0;endcase
   1:case({y[0],x[0]})0:pixel_channel=1;1:pixel_channel=0;2:pixel_channel=3;default:pixel_channel=2;endcase
   2:case({y[0],x[0]})0:pixel_channel=2;1:pixel_channel=3;2:pixel_channel=0;default:pixel_channel=1;endcase
  endcase
 end
 assign cfg_ready=rst_n&&ce&&!cfg_pending&&!cfg_commit_valid;
 assign cfg_commit_ready=rst_n&&ce&&!cfg_pending&&!cfg_valid;
 assign start_ready=rst_n&&ce&&state==IDLE&&configured&&!cfg_pending&&!cfg_valid&&!cfg_commit_valid;
 assign s_ready=rst_n&&ce&&state==INPUT;
 assign m_valid=rst_n&&state==HOLD;
 assign m_sof=m_valid&&pixel==0;assign m_eol=m_valid&&x==WIDTH-1;assign m_last=m_valid&&pixel==N-1;
 assign done_valid=rst_n&&state==DONE;
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||N>65536||(BITS!=8&&BITS!=10&&BITS!=12)||GRID_WIDTH<2||GRID_WIDTH>9||GRID_HEIGHT<2||GRID_HEIGHT>9||GAIN_BITS<2||GAIN_BITS>24||GAIN_FRAC<0||GAIN_FRAC>20)$fatal(1,"lens_shading invalid parameters");
 end
 // Inactive-map writes and active-map synchronous reads have separate ports.
 always @(posedge clk)if(rst_n&&ce)begin
  if(cfg_valid&&cfg_ready&&cfg_index<ENTRIES)maps[(active_bank?0:ENTRIES)+cfg_index]<=cfg_gain;
  if(state==READ_GAIN)gain_q<=maps[gain_read_address];
 end
 always @(posedge clk)begin
  if(!rst_n)begin state<=IDLE;return_state<=IDLE;written<=0;active_bank<=0;configured<=0;cfg_error<=0;cfg_pending<=0;pattern<=0;channel<=0;corner<=0;pixel<=0;x<=0;y<=0;cell_x<=0;cell_y<=0;rx<=0;ry<=0;step<=0;done_error<=0;error_code<=0;m_data<=0;m_saturated<=0;end
  else if(ce)begin
   if(cfg_valid&&cfg_ready)begin
    if(cfg_index>=ENTRIES)cfg_error<=1;
    else begin written[cfg_index]<=1;cfg_error<=0;end
   end
   if(cfg_commit_valid&&cfg_commit_ready)begin
    if(!(&written))cfg_error<=1;
    else begin cfg_error<=0;
     if(state==IDLE&&!start_valid)begin active_bank<=!active_bank;configured<=1;written<=0;end
     else cfg_pending<=1;
    end
   end
   case(state)
    IDLE:begin
     if(cfg_pending)begin active_bank<=!active_bank;configured<=1;written<=0;cfg_pending<=0;end
     else if(start_valid&&start_ready)begin pattern<=cfg_pattern;pixel<=0;x<=0;y<=0;done_error<=0;error_code<=0;state<=INPUT;end
    end
    INPUT:if(capture)begin
     if(s_sof!=(pixel==0)||s_eol!=(x==WIDTH-1)||s_last!=(pixel==N-1))begin done_error<=1;error_code<=1;state<=DONE;end
     else begin raw<=s_data;cell_x<=ix;cell_y<=iy;rx<=fracx;ry<=fracy;channel<=pixel_channel;corner<=0;weighted_gain<=0;state<=READ_GAIN;end
    end
    READ_GAIN:state<=USE_GAIN;
    USE_GAIN:begin
     current_gain<=gain_q;multiplicand<={32'd0,weight_x};multiplier<=weight_y;mul_sum<=0;step<=0;return_state<=WEIGHT_RESULT;state<=MUL_STEP;
    end
    MUL_STEP:begin
     mul_sum<=mul_next;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
     if(step==31)begin product<=mul_next;state<=return_state;end else step<=step+1;
    end
    WEIGHT_RESULT:begin multiplicand<=product;multiplier<=current_gain;mul_sum<=0;step<=0;return_state<=TERM_RESULT;state<=MUL_STEP;end
    TERM_RESULT:begin weighted_gain<=weighted_gain+product;if(corner==3)state<=RAW_INIT;else begin corner<=corner+1;state<=READ_GAIN;end end
    RAW_INIT:begin multiplicand<=weighted_gain;multiplier<=raw;mul_sum<=0;step<=0;return_state<=RAW_RESULT;state<=MUL_STEP;end
    RAW_RESULT:begin numerator<=product;quotient<=0;remainder<=0;step<=0;state<=DIV_STEP;end
    DIV_STEP:begin
     numerator<=numerator<<1;quotient<=quotient<<1;
     if(shifted_remainder>={1'b0,DENOMINATOR})begin remainder<=shifted_remainder-{1'b0,DENOMINATOR};quotient[0]<=1;end else remainder<=shifted_remainder;
     if(step==63)state<=DIV_ROUND;else step<=step+1;
    end
    DIV_ROUND:begin rounded<=quotient+(({remainder,1'b0}>={2'b0,DENOMINATOR})?64'd1:64'd0);state<=DIV_SAVE;end
    DIV_SAVE:begin m_saturated<=rounded>RAW_MAX;m_data<=rounded>RAW_MAX?RAW_MAX[BITS-1:0]:rounded[BITS-1:0];state<=HOLD;end
    HOLD:if(m_ready)begin
     if(pixel==N-1)state<=DONE;
     else begin pixel<=pixel+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=INPUT;end
    end
    DONE:if(done_ready)state<=IDLE;
    default:begin done_error<=1;error_code<=2;state<=DONE;end
   endcase
  end
 end
endmodule
