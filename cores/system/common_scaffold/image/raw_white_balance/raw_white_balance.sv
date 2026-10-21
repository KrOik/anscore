// Same-frame four-CFA gray-world RAW white balance. No host-computed auto gains.
module raw_white_balance #(
 parameter integer WIDTH=32, HEIGHT=24, BITS=12
)(
 input wire clk,rst_n,ce,
 input wire start_valid, output wire start_ready,
 input wire cfg_auto, input wire [1:0] cfg_pattern,
 input wire [15:0] cfg_roi_x0,cfg_roi_y0,cfg_roi_x1,cfg_roi_y1,
 input wire [BITS-1:0] cfg_low,cfg_high,
 input wire [15:0] cfg_gain_min,cfg_gain_max,
 input wire [63:0] cfg_manual_gains,
 input wire [BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,s_last,
 output reg [BITS-1:0] m_data,output reg m_saturated,
 output reg m_valid,input wire m_ready,
 output reg m_sof,m_eol,m_last,
 output reg done_valid,input wire done_ready,
 output reg done_error,output reg [3:0] error_code,
 output wire [127:0] stats_sums,stats_counts,
 output wire [63:0] applied_gains,
 output wire [63:0] green_sum,output wire [31:0] green_count
);
 localparam integer N=WIDTH*HEIGHT, AW=(N<2)?1:$clog2(N);
 localparam IDLE=0,CAPTURE=1,PREP=2,MUL=3,DEN_PREP=4,DIV_PREP=5,
 DIVIDE=6,GAIN_NEXT=7,READ=8,READ_WAIT=9,OUT_PREP=10,OUT_WAIT=11,DONE=12;
 reg [3:0] state,return_state;
 reg auto_mode;reg [1:0] pattern,plane;
 reg [15:0] x,y,x0,y0,x1,y1,gmin,gmax;
 reg [BITS-1:0] low_gate,high_gate;
 reg [31:0] sums[0:3],counts[0:3];reg [15:0] gains[0:3];
 reg [AW-1:0] addr;
 reg [BITS-1:0] frame[0:N-1];reg [BITS-1:0] read_data;
 reg [63:0] mul_acc,mul_a,mul_result,numerator,denominator;
 reg [31:0] mul_b;
 reg [6:0] iter;
 reg [63:0] div_q,div_r;
 wire [63:0] shifted_r={div_r[62:0],div_q[63]};
 wire [63:0] sum_g={32'b0,sums[1]}+sums[2];
 wire [31:0] count_g=counts[1]+counts[2];
 wire [1:0] raster={y[0],x[0]};
 // Canonical physical Bayer parity -> R,Gr,Gb,B plane.
 wire [1:0] cfa_plane=(pattern==0)?raster:
                         (pattern==1)?(raster^2'b01):
                         (pattern==2)?(raster^2'b10):(raster^2'b11);
 wire accept=s_valid&&s_ready;
 wire marker_bad=(s_sof!=(addr==0))||(s_eol!=(x==WIDTH-1))||(s_last!=(addr==N-1));
 assign start_ready=ce&&rst_n&&(state==IDLE);
 assign s_ready=ce&&rst_n&&(state==CAPTURE);
 assign stats_sums={sums[3],sums[2],sums[1],sums[0]};
 assign stats_counts={counts[3],counts[2],counts[1],counts[0]};
 assign applied_gains={gains[3],gains[2],gains[1],gains[0]};
 assign green_sum=sum_g;assign green_count=count_g;
 integer i;
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||N>65536||
      (BITS!=8&&BITS!=10&&BITS!=12)) $fatal(1,"invalid RAW AWB parameters");
 end
 // A single synchronous coefficient/pixel RAM, no reset on RAM contents.
 always @(posedge clk) if(ce&&rst_n) begin
  if(accept&&!marker_bad) frame[addr]<=s_data;
  if(state==READ) read_data<=frame[addr];
 end
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE;m_valid<=0;done_valid<=0;done_error<=0;error_code<=0;
   m_data<=0;m_saturated<=0;m_sof<=0;m_eol<=0;m_last<=0;
   x<=0;y<=0;addr<=0;plane<=0;auto_mode<=0;pattern<=0;
   x0<=0;x1<=0;y0<=0;y1<=0;low_gate<=0;high_gate<=0;gmin<=0;gmax<=0;
   mul_acc<=0;mul_a<=0;mul_b<=0;mul_result<=0;return_state<=IDLE;
   numerator<=0;denominator<=0;iter<=0;div_q<=0;div_r<=0;
   for(i=0;i<4;i=i+1) begin sums[i]<=0;counts[i]<=0;gains[i]<=0;end
  end else if(ce) case(state)
   IDLE: if(start_valid) begin
    auto_mode<=cfg_auto;pattern<=cfg_pattern;x0<=cfg_roi_x0;y0<=cfg_roi_y0;
    x1<=cfg_roi_x1;y1<=cfg_roi_y1;low_gate<=cfg_low;high_gate<=cfg_high;
    gmin<=cfg_gain_min;gmax<=cfg_gain_max;x<=0;y<=0;addr<=0;plane<=0;
    done_error<=0;error_code<=0;m_valid<=0;
    for(i=0;i<4;i=i+1) begin sums[i]<=0;counts[i]<=0;gains[i]<=cfg_manual_gains[i*16+:16];end
    if(cfg_roi_x0>cfg_roi_x1||cfg_roi_y0>cfg_roi_y1||cfg_roi_x1>=WIDTH||cfg_roi_y1>=HEIGHT||
       cfg_low>cfg_high||cfg_gain_min>cfg_gain_max) begin
     done_valid<=1;done_error<=1;error_code<=1;state<=DONE;
    end else if(!cfg_auto&&
      ((cfg_manual_gains[15:0]<cfg_gain_min)||(cfg_manual_gains[15:0]>cfg_gain_max)||
       (cfg_manual_gains[31:16]<cfg_gain_min)||(cfg_manual_gains[31:16]>cfg_gain_max)||
       (cfg_manual_gains[47:32]<cfg_gain_min)||(cfg_manual_gains[47:32]>cfg_gain_max)||
       (cfg_manual_gains[63:48]<cfg_gain_min)||(cfg_manual_gains[63:48]>cfg_gain_max))) begin
     done_valid<=1;done_error<=1;error_code<=1;state<=DONE;
    end else state<=CAPTURE;
   end
   CAPTURE: if(accept) begin
    if(marker_bad) begin done_valid<=1;done_error<=1;error_code<=2;state<=DONE;end
    else begin
     if(x>=x0&&x<=x1&&y>=y0&&y<=y1&&s_data>=low_gate&&s_data<=high_gate) begin
      sums[cfa_plane]<=sums[cfa_plane]+s_data;counts[cfa_plane]<=counts[cfa_plane]+1;
     end
     if(addr==N-1) begin
      addr<=0;x<=0;y<=0;plane<=0;state<=auto_mode?PREP:READ;
     end else begin addr<=addr+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end
    end
   end
   PREP: begin
    if(count_g==0||sum_g==0||counts[plane]==0||sums[plane]==0) begin
     done_valid<=1;done_error<=1;error_code<=(counts[plane]==0||count_g==0)?3:4;state<=DONE;
    end else begin
     mul_a<=sum_g;mul_b<=counts[plane];mul_acc<=0;iter<=0;return_state<=DEN_PREP;state<=MUL;
    end
   end
   MUL: begin
    mul_acc<=mul_acc+(mul_b[0]?mul_a:64'd0);mul_a<=mul_a<<1;mul_b<=mul_b>>1;
    if(iter==31) begin mul_result<=mul_acc+(mul_b[0]?mul_a:64'd0);state<=return_state;end
    else iter<=iter+1;
   end
   DEN_PREP:begin
    numerator<=mul_result<<12;mul_a<={32'b0,sums[plane]};mul_b<=count_g;
    mul_acc<=0;iter<=0;return_state<=DIV_PREP;state<=MUL;
   end
   DIV_PREP:begin
    denominator<=mul_result;div_q<=numerator+(mul_result>>1);div_r<=0;iter<=0;state<=DIVIDE;
   end
   DIVIDE:begin
    if(shifted_r>=denominator)begin div_r<=shifted_r-denominator;div_q<={div_q[62:0],1'b1};end
    else begin div_r<=shifted_r;div_q<={div_q[62:0],1'b0};end
    if(iter==63)state<=GAIN_NEXT;else iter<=iter+1;
   end
   GAIN_NEXT:begin
    gains[plane]<=(div_q<gmin)?gmin:((div_q>gmax)?gmax:div_q[15:0]);
    if(plane==3)begin addr<=0;x<=0;y<=0;state<=READ;end
    else begin plane<=plane+1;state<=PREP;end
   end
   READ:state<=READ_WAIT;
   READ_WAIT:begin
    mul_a<={{(64-BITS){1'b0}},read_data};mul_b<={16'b0,gains[cfa_plane]};
    mul_acc<=0;iter<=0;return_state<=OUT_PREP;state<=MUL;
   end
   OUT_PREP:begin
    if(((mul_result+64'd2048)>>12)>((1<<BITS)-1))begin m_data<={BITS{1'b1}};m_saturated<=1;end
    else begin m_data<=(mul_result+64'd2048)>>12;m_saturated<=0;end
    m_sof<=addr==0;m_eol<=x==WIDTH-1;m_last<=addr==N-1;m_valid<=1;state<=OUT_WAIT;
   end
   OUT_WAIT:if(m_ready)begin
    m_valid<=0;
    if(addr==N-1)begin done_valid<=1;state<=DONE;end
    else begin addr<=addr+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=READ;end
   end
   DONE:if(done_ready)begin done_valid<=0;state<=IDLE;end
   default:begin m_valid<=0;done_valid<=1;done_error<=1;error_code<=5;state<=DONE;end
  endcase
 end
endmodule
