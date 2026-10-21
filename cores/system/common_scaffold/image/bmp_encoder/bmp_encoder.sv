// BMP24 BI_RGB encoder. Input raster is always top to bottom, RGB888.
// A synchronous frame RAM permits either signed-height top-down or bottom-up BMP.
module bmp_encoder #(parameter WIDTH=16, HEIGHT=12)(
 input wire clk,rst_n,ce,start_valid,abort,input wire cfg_top_down,
 output wire start_ready,input wire [23:0] s_pixel,
 input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output wire [7:0] m_data,output wire m_valid,m_sof,m_last,input wire m_ready,
 output wire done_valid,done_error,output reg [7:0] error_code,
 input wire done_ready,output wire busy,output reg [31:0] output_bytes);
 localparam N=WIDTH*HEIGHT, STRIDE=((WIDTH*3+3)/4)*4, SIZE=54+STRIDE*HEIGHT;
 localparam IDLE=0,CAP=1,HEAD=2,READ=3,WAITRAM=4,PIX=5,PAD=6,DONE=7;
 reg[3:0] state;reg top_down;reg[23:0] mem[0:N-1];reg[23:0] q;
 integer input_index,header_index,x,y,channel,padding;
 wire [31:0] signed_height=top_down ? -HEIGHT : HEIGHT;
 reg[7:0] header_byte;
 always @* begin
 header_byte=0;
 case(header_index)
 0:header_byte=8'h42;1:header_byte=8'h4d;
 2,3,4,5:header_byte=SIZE >> ((header_index-2)*8);
 10:header_byte=54;14:header_byte=40;
 18,19,20,21:header_byte=WIDTH >> ((header_index-18)*8);
 22,23,24,25:header_byte=signed_height >> ((header_index-22)*8);
 26:header_byte=1;28:header_byte=24;
 34,35,36,37:header_byte=(STRIDE*HEIGHT) >> ((header_index-34)*8);
 endcase
 end
 assign start_ready=state==IDLE;
 assign s_ready=state==CAP;
 assign m_valid=state==HEAD||state==PIX||state==PAD;
 assign m_data=state==HEAD ? header_byte : state==PAD ? 0 : channel==0 ? q[7:0] : channel==1 ? q[15:8] : q[23:16];
 assign m_sof=state==HEAD&&header_index==0;
 assign m_last=m_valid&&output_bytes==SIZE-1;
 assign done_valid=state==DONE;assign done_error=error_code!=0;assign busy=state!=IDLE;
 always @(posedge clk) begin
 if(!rst_n)begin state<=IDLE;error_code<=0;output_bytes<=0;top_down<=0;input_index<=0;header_index<=0;x<=0;y<=0;channel<=0;padding<=0;q<=0;end
 else if(ce) begin
 if(abort&&state!=IDLE&&state!=DONE)begin state<=DONE;error_code<=2;end
 else case(state)
 IDLE:if(start_valid)begin error_code<=0;output_bytes<=0;top_down<=cfg_top_down;input_index<=0;
 if(WIDTH<1||HEIGHT<1||WIDTH>256||HEIGHT>256)begin state<=DONE;error_code<=1;end else state<=CAP;end
 CAP:if(s_valid)begin
 if(s_sof!=(input_index==0)||s_eol!=(input_index%WIDTH==WIDTH-1)||s_last!=(input_index==N-1))begin state<=DONE;error_code<=3;end
 else begin mem[input_index]<=s_pixel;if(input_index==N-1)begin state<=HEAD;header_index<=0;x<=0;y<=0;end else input_index<=input_index+1;end end
 HEAD:if(m_ready)begin output_bytes<=output_bytes+1;if(header_index==53)state<=READ;else header_index<=header_index+1;end
 READ:begin q<=mem[(top_down?y:HEIGHT-1-y)*WIDTH+x];state<=WAITRAM;end
 WAITRAM:begin channel<=0;state<=PIX;end
 PIX:if(m_ready)begin output_bytes<=output_bytes+1;
 if(channel<2)channel<=channel+1;
 else if(x<WIDTH-1)begin x<=x+1;state<=READ;end
 else if(STRIDE>WIDTH*3)begin padding<=0;state<=PAD;end
 else if(y==HEIGHT-1)state<=DONE;
 else begin y<=y+1;x<=0;state<=READ;end end
 PAD:if(m_ready)begin output_bytes<=output_bytes+1;
 if(padding<STRIDE-WIDTH*3-1)padding<=padding+1;
 else if(y==HEIGHT-1)state<=DONE;
 else begin y<=y+1;x<=0;state<=READ;end end
 DONE:if(done_ready)state<=IDLE;
 default:begin state<=DONE;error_code<=4;end
 endcase
 end
 end
endmodule
