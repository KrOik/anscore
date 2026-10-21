// Complex, programmable 1/3/5/7-tap-side Gabor convolution. Verilog-2005.
// Coefficients are signed 16-bit row-major convolution weights, NOT correlation.
// Re-upload the entire kernel after every START. Replicate-border grayscale.
module gabor_filter_frame #(parameter WIDTH=7,HEIGHT=5)(
 input clk,rst_n,ce,input start_valid,output start_ready,
 input [3:0] cfg_size,input [4:0] cfg_shift,
 input signed [15:0] c_real,c_imag,input c_valid,c_first,c_last,output c_ready,
 input [7:0] s_pixel,input s_valid,s_sof,s_eol,s_last,output s_ready,
 output reg signed [31:0] m_real,m_imag,output reg m_valid,input m_ready,
 output reg m_sof,m_eol,m_last,
 output done_valid,input done_ready,output reg done_error,output reg [3:0] error_code,
 output busy
);
 localparam GOOD=WIDTH>=1&&WIDTH<=32&&HEIGHT>=1&&HEIGHT<=32;
 localparam N=GOOD?WIDTH*HEIGHT:1;
 localparam IDLE=0,KERNEL=1,CAPTURE=2,TAP_ADDR=3,TAP_WAIT=4,
 TAP_LOAD=5,MULTIPLY=6,FINISH=7,OUTPUT=8,DONE=9;
 reg [3:0] state;
 reg [7:0] frame_mem[0:N-1],frame_q;
 reg [31:0] coefficient_mem[0:48],coefficient_q;
 reg [9:0] position,frame_address;
 reg [5:0] x,y,tap_index,kernel_last;
 reg [2:0] side,radius,tx,ty;
 reg [4:0] shift;
 reg bad_frame,imag_part;
 reg [7:0] factor;
 reg [2:0] bit_index;
 reg signed [31:0] mul_shift,mul_acc,sum_real,sum_imag;
 wire signed [31:0] mul_next=mul_acc+(factor[0]?mul_shift:32'sd0);
 wire signed [7:0] sx=$signed({2'b00,x})-$signed({5'b0,tx})+$signed({5'b0,radius});
 wire signed [7:0] sy=$signed({2'b00,y})-$signed({5'b0,ty})+$signed({5'b0,radius});
 wire [5:0] sample_x=sx<0?6'd0:(sx>=WIDTH?WIDTH-1:sx[5:0]);
 wire [5:0] sample_y=sy<0?6'd0:(sy>=HEIGHT?HEIGHT-1:sy[5:0]);
 wire marker_bad=(s_sof!=(position==0))||(s_eol!=(x==WIDTH-1))||(s_last!=(position==N-1));
 wire [32:0] abs_real=sum_real<0?-$signed({sum_real[31],sum_real}):{1'b0,sum_real};
 wire [32:0] abs_imag=sum_imag<0?-$signed({sum_imag[31],sum_imag}):{1'b0,sum_imag};
 wire [32:0] half_unit=shift==0?33'd0:(33'd1<<(shift-1'b1));
 wire [32:0] rounded_real=(abs_real+half_unit)>>shift;
 wire [32:0] rounded_imag=(abs_imag+half_unit)>>shift;
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign c_ready=rst_n&&ce&&state==KERNEL;
 assign s_ready=rst_n&&ce&&state==CAPTURE;
 assign done_valid=rst_n&&state==DONE;
 assign busy=state!=IDLE;
 // Both data stores have synchronous reads and clock enable.
 always @(posedge clk)if(ce)begin
  frame_q<=frame_mem[frame_address];coefficient_q<=coefficient_mem[tap_index];
 end
 always @(posedge clk)begin
 if(!rst_n)begin
  state<=IDLE;m_valid<=0;m_real<=0;m_imag<=0;m_sof<=0;m_eol<=0;m_last<=0;
  done_error<=0;error_code<=0;frame_address<=0;tap_index<=0;
 end else if(ce)case(state)
 IDLE:if(start_valid)begin
  done_error<=0;error_code<=0;m_valid<=0;m_real<=0;m_imag<=0;m_sof<=0;m_eol<=0;m_last<=0;
  if(!GOOD||!(cfg_size==1||cfg_size==3||cfg_size==5||cfg_size==7)||cfg_shift>20)begin
   done_error<=1;error_code<=1;state<=DONE;
  end else begin
   side<=cfg_size[2:0];radius<=cfg_size>>1;shift<=cfg_shift;
   kernel_last<=cfg_size*cfg_size-1'b1;tap_index<=0;bad_frame<=0;state<=KERNEL;
  end
 end
 KERNEL:if(c_valid)begin
  if(c_first!=(tap_index==0)||c_last!=(tap_index==kernel_last))begin
   done_error<=1;error_code<=2;state<=DONE;
  end else begin
   coefficient_mem[tap_index]<={c_imag,c_real};
   if(tap_index==kernel_last)begin position<=0;x<=0;y<=0;state<=CAPTURE;end
   else tap_index<=tap_index+1'b1;
  end
 end
 CAPTURE:if(s_valid)begin
  frame_mem[position]<=s_pixel;
  if(marker_bad)bad_frame<=1;
  if(position==N-1)begin
   if(bad_frame||marker_bad)begin done_error<=1;error_code<=3;state<=DONE;end
   else begin position<=0;x<=0;y<=0;tx<=0;ty<=0;tap_index<=0;
    sum_real<=0;sum_imag<=0;state<=TAP_ADDR;end
  end else begin position<=position+1'b1;
   if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
  end
 end
 TAP_ADDR:begin frame_address<=sample_y*WIDTH+sample_x;state<=TAP_WAIT;end
 TAP_WAIT:state<=TAP_LOAD;
 TAP_LOAD:begin
  mul_acc<=0;mul_shift<={{16{coefficient_q[15]}},coefficient_q[15:0]};
  factor<=frame_q;bit_index<=0;imag_part<=0;state<=MULTIPLY;
 end
 MULTIPLY:begin
  mul_acc<=mul_next;mul_shift<=mul_shift<<<1;factor<=factor>>1;
  if(bit_index==7)begin
   if(!imag_part)begin
    sum_real<=sum_real+mul_next;mul_acc<=0;
    mul_shift<={{16{coefficient_q[31]}},coefficient_q[31:16]};factor<=frame_q;
    bit_index<=0;imag_part<=1;
   end else begin
    sum_imag<=sum_imag+mul_next;
    if(tap_index==kernel_last)state<=FINISH;
    else begin tap_index<=tap_index+1'b1;
     if(tx==side-1'b1)begin tx<=0;ty<=ty+1'b1;end else tx<=tx+1'b1;
     state<=TAP_ADDR;
    end
   end
  end else bit_index<=bit_index+1'b1;
 end
 FINISH:begin
  m_real<=sum_real<0?-$signed(rounded_real[31:0]):$signed(rounded_real[31:0]);
  m_imag<=sum_imag<0?-$signed(rounded_imag[31:0]):$signed(rounded_imag[31:0]);
  m_valid<=1;m_sof<=position==0;m_eol<=x==WIDTH-1;m_last<=position==N-1;state<=OUTPUT;
 end
 OUTPUT:if(m_ready)begin
  m_valid<=0;
  if(position==N-1)state<=DONE;
  else begin position<=position+1'b1;
   if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
   tx<=0;ty<=0;tap_index<=0;sum_real<=0;sum_imag<=0;state<=TAP_ADDR;
  end
 end
 DONE:if(done_ready)state<=IDLE;
 default:begin m_valid<=0;done_error<=1;error_code<=4;state<=DONE;end
 endcase
 end
endmodule
