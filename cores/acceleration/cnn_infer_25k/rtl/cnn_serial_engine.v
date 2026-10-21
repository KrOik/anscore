// Complete fixed28x28 INT8 CNN. Scalar dot reuse, synchronous byte memories.
// Loader requires sequential addresses, restarting a region at address0.
// Tap stages:0/1 conv1 acc/quant,2 pool1,3/4 conv2 acc/quant,5 pool2,6 scores,7 Top3.
module cnn_serial_engine(
 input wire clk,rst_n,
 input wire load_valid,output wire load_ready,input wire [1:0] load_region,
 input wire [15:0] load_addr,input wire [31:0] load_data,output reg load_error,
 input wire start,output wire start_ready,
 output wire tap_valid,input wire tap_ready,output reg [2:0] tap_stage,
 output reg [15:0] tap_index,output reg signed [31:0] tap_data,
 output wire done_valid,input wire done_ready,output reg [3:0] done_error,
 output reg [31:0] run_cycles
);
 localparam IDLE=0,BIAS_ADDR=1,BIAS_WAIT=2,DOT_CMD=3,TERM_ADDR=4,TERM_WAIT=5,
  TERM_SEND=6,DOT_WAIT=7,TAP_ACC=8,TAP_QUANT=9,POOL_ADDR=10,POOL_WAIT=11,
  POOL_CAPTURE=12,POOL_TAP=13,TOP_SCAN=14,TOP_TAP=15,FINISH=16;
 reg [4:0] state;
 reg [1:0] layer,subpixel;
 reg [9:0] position,term,pool_position;
 reg [3:0] channel,scan,top_emit;
 reg [15:0] image_loaded,weights_loaded,biases_loaded;
 reg signed [7:0] image[0:783];
 reg signed [7:0] fmap[0:3135];
 reg signed [7:0] weights[0:4243];
 reg signed [31:0] biases[0:21];
 reg signed [7:0] image_q,weight_q;
 reg [7:0] fmap_q,pool_max;
 reg signed [31:0] bias_q,bias_value,acc_value;
 reg [7:0] quant_value;
 reg pad_q;
 reg signed [31:0] scores[0:9];
 reg signed [31:0] best0,best1,best2;
 reg [3:0] id0,id1,id2;
 integer read_image,read_weight,read_fmap,read_bias;
 integer width,channels,ci,xx,yy,k,ic;
 reg padding;
 wire [15:0] dot_terms=layer==0?16'd9:layer==1?16'd36:16'd392;
 wire [3:0] channel_count=layer==0?4:8;
 wire [9:0] positions=layer==0?784:196;
 wire [9:0] pool_positions=layer==0?196:49;
 // Widen before array indexing: an uncontextualized10-bit position product
 // otherwise wraps at1024 and overwrites earlier feature-map locations.
 wire [15:0] fmap_write_addr={6'd0,position}*channel_count+channel;
 wire [15:0] pool_write_addr={6'd0,pool_position}*channel_count+channel;
 wire dot_cr,dot_sr,dot_mv;wire signed [31:0] dot_result;wire [1:0] dot_error;
 wire signed [7:0] dot_x=pad_q?8'sd0:image_q;
 int8_dot_stream dot(clk,rst_n,state==DOT_CMD,dot_cr,dot_terms,bias_value,
  state==TERM_SEND,dot_sr,dot_x,weight_q,term==dot_terms-1,
  dot_mv,state==DOT_WAIT||(dot_error!=0&&state!=IDLE&&state!=FINISH),dot_result,dot_error);
 assign load_ready=rst_n&&state==IDLE&&!start;
 assign start_ready=rst_n&&state==IDLE;
 assign done_valid=rst_n&&state==FINISH;
 assign tap_valid=rst_n&&(state==TAP_ACC||state==TAP_QUANT||state==POOL_TAP||state==TOP_TAP);
 always @* begin
  width=layer==0?28:14;channels=layer==0?4:8;ci=layer==0?1:4;
  k=term%9;ic=term/9;
  yy=(layer==0?position/28:position/14)+k/3-1;
  xx=(layer==0?position%28:position%14)+k%3-1;
  padding=layer!=2&&(xx<0||xx>=width||yy<0||yy>=width);
  read_image=layer==2?term:padding?0:layer==0?yy*28+xx:(yy*14+xx)*4+ic;
  read_weight=layer==0?channel*9+term:layer==1?36+channel*36+term:324+channel*392+term;
  read_bias=layer==0?channel:layer==1?4+channel:12+channel;
  read_fmap=layer==0?
   (((pool_position/14)*2+subpixel/2)*28+(pool_position%14)*2+subpixel%2)*4+channel:
   (((pool_position/7)*2+subpixel/2)*14+(pool_position%7)*2+subpixel%2)*8+channel;
  tap_stage=0;tap_index=0;tap_data=0;
  if(state==TAP_ACC)begin
   tap_stage=layer==0?0:layer==1?3:6;
   tap_index=layer==2?channel:position*channel_count+channel;tap_data=acc_value;
  end else if(state==TAP_QUANT)begin
   tap_stage=layer==0?1:4;tap_index=position*channel_count+channel;tap_data={24'd0,quant_value};
  end else if(state==POOL_TAP)begin
   tap_stage=layer==0?2:5;tap_index=pool_position*channel_count+channel;tap_data={24'd0,pool_max};
  end else if(state==TOP_TAP)begin
   tap_stage=7;tap_index=top_emit;tap_data=top_emit==0?{28'd0,id0}:top_emit==1?{28'd0,id1}:{28'd0,id2};
  end
 end
 // Single registered read port per storage array; no asynchronous tensor reads.
 always @(posedge clk)begin
  if(state==TERM_ADDR)begin image_q<=image[read_image];weight_q<=weights[read_weight];end
  if(state==BIAS_ADDR)bias_q<=biases[read_bias];
  if(state==POOL_ADDR)fmap_q<=fmap[read_fmap];
  if(rst_n&&load_valid&&load_ready)begin
   if(load_region==0&&load_addr<784&&(load_addr==0||load_addr==image_loaded))image[load_addr]<=load_data[7:0];
   if(load_region==1&&load_addr<4244&&(load_addr==0||load_addr==weights_loaded))weights[load_addr]<=load_data[7:0];
   if(load_region==2&&load_addr<22&&(load_addr==0||load_addr==biases_loaded))biases[load_addr]<=load_data;
  end
  if(state==DOT_WAIT&&dot_mv&&dot_error==0&&layer!=2)
   fmap[fmap_write_addr]<=dot_result<0?0:dot_result>=16384?127:dot_result[14:7];
  if(state==POOL_TAP&&tap_ready)image[pool_write_addr]<=pool_max;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;layer<=0;subpixel<=0;position<=0;term<=0;pool_position<=0;channel<=0;
   scan<=0;top_emit<=0;image_loaded<=0;weights_loaded<=0;biases_loaded<=0;
   load_error<=0;done_error<=0;run_cycles<=0;bias_value<=0;acc_value<=0;
   quant_value<=0;pool_max<=0;pad_q<=0;
   best0<=0;best1<=0;best2<=0;id0<=15;id1<=15;id2<=15;
  end else begin
   load_error<=0;
   if(state!=IDLE&&state!=FINISH)run_cycles<=run_cycles+1'b1;
   if(load_valid&&load_ready)begin
    case(load_region)
     0:if(load_addr<784&&(load_addr==0||load_addr==image_loaded))image_loaded<=load_addr+1'b1;else load_error<=1;
     1:if(load_addr<4244&&(load_addr==0||load_addr==weights_loaded))weights_loaded<=load_addr+1'b1;else load_error<=1;
     2:if(load_addr<22&&(load_addr==0||load_addr==biases_loaded))biases_loaded<=load_addr+1'b1;else load_error<=1;
     default:load_error<=1;
    endcase
   end
   case(state)
    IDLE:if(start)begin
     run_cycles<=0;done_error<=0;layer<=0;position<=0;channel<=0;
     // Every run overwrites image RAM during pooling; require a fresh input.
     image_loaded<=0;
     if(image_loaded!=784||weights_loaded!=4244||biases_loaded!=22)begin done_error<=1;state<=FINISH;end
     else state<=BIAS_ADDR;
    end
    BIAS_ADDR:state<=BIAS_WAIT;
    BIAS_WAIT:begin bias_value<=bias_q;state<=DOT_CMD;end
    DOT_CMD:if(dot_cr)begin term<=0;state<=TERM_ADDR;end
    TERM_ADDR:begin pad_q<=padding;state<=TERM_WAIT;end
    TERM_WAIT:state<=TERM_SEND;
    TERM_SEND:if(dot_sr)begin
     if(term==dot_terms-1)state<=DOT_WAIT;
     else begin term<=term+1'b1;state<=TERM_ADDR;end
    end
    DOT_WAIT:if(dot_mv)begin
     if(dot_error!=0)begin done_error<=4+{2'd0,dot_error};state<=FINISH;end
     else begin
      acc_value<=dot_result;quant_value<=dot_result<0?0:dot_result>=16384?127:dot_result[14:7];
      if(layer==2)scores[channel]<=dot_result;
      state<=TAP_ACC;
     end
    end
    TAP_ACC:if(tap_ready)begin
     if(layer!=2)state<=TAP_QUANT;
     else if(channel<9)begin channel<=channel+1'b1;state<=BIAS_ADDR;end
     else begin scan<=0;id0<=15;id1<=15;id2<=15;state<=TOP_SCAN;end
    end
    TAP_QUANT:if(tap_ready)begin
     if(channel<channel_count-1)begin channel<=channel+1'b1;state<=BIAS_ADDR;end
     else if(position<positions-1)begin channel<=0;position<=position+1'b1;state<=BIAS_ADDR;end
     else begin channel<=0;pool_position<=0;subpixel<=0;pool_max<=0;state<=POOL_ADDR;end
    end
    POOL_ADDR:state<=POOL_WAIT;
    POOL_WAIT:state<=POOL_CAPTURE;
    POOL_CAPTURE:begin
     if(fmap_q>pool_max)pool_max<=fmap_q;
     if(subpixel==3)state<=POOL_TAP;
     else begin subpixel<=subpixel+1'b1;state<=POOL_ADDR;end
    end
    POOL_TAP:if(tap_ready)begin
     subpixel<=0;pool_max<=0;
     if(channel<channel_count-1)begin channel<=channel+1'b1;state<=POOL_ADDR;end
     else if(pool_position<pool_positions-1)begin channel<=0;pool_position<=pool_position+1'b1;state<=POOL_ADDR;end
     else begin layer<=layer+1'b1;position<=0;channel<=0;state<=BIAS_ADDR;end
    end
    TOP_SCAN:begin
     if(id0==15||scores[scan]>best0||(scores[scan]==best0&&scan<id0))begin
      best2<=best1;id2<=id1;best1<=best0;id1<=id0;best0<=scores[scan];id0<=scan;
     end else if(id1==15||scores[scan]>best1||(scores[scan]==best1&&scan<id1))begin
      best2<=best1;id2<=id1;best1<=scores[scan];id1<=scan;
     end else if(id2==15||scores[scan]>best2||(scores[scan]==best2&&scan<id2))begin best2<=scores[scan];id2<=scan;end
     if(scan==9)begin top_emit<=0;state<=TOP_TAP;end else scan<=scan+1'b1;
    end
    TOP_TAP:if(tap_ready)begin
     if(top_emit==2)state<=FINISH;else top_emit<=top_emit+1'b1;
    end
    FINISH:if(done_ready)state<=IDLE;
    default:state<=IDLE;
   endcase
   // A malformed loaded bias may overflow before the final term. Consume the
   // dot error immediately rather than waiting forever for its input ready.
   if(dot_mv&&dot_error!=0&&state!=IDLE&&state!=FINISH)begin
    done_error<=4+{2'd0,dot_error};state<=FINISH;
   end
  end
 end
endmodule
