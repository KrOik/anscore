// FCS-qualified Ethernet frame stream; FCS/preamble excluded. Common50MHz
// RMII/application clock. Metadata timestamp is dequeue time, not wire arrival.
module rmii_frame_stream(
 input wire clk,rst_n,crs,input wire [1:0] rxd,
 output wire m_valid,input wire m_ready,output reg [7:0] m_data,
 output wire m_keep,m_last,output wire [95:0] m_user,
 output wire [31:0] rx_good,rx_bad,rx_overflow,
 output reg [31:0] delivered_frames,delivered_bytes
);
 localparam IDLE=0,FETCH=1,LATCH=2,OFFER=3,RELEASE=4;
 reg [2:0] state;
 wire [1:0] pending;wire [10:0] len0,len1;wire [7:0] q;
 reg bank;reg [10:0] address,length;
 reg [31:0] frame_seq;reg [63:0] timestamp;
 wire [63:0] now;
 sys_timestamp64 clock_counter(.clk(clk),.rst_n(rst_n),.load_valid(1'b0),
  .load_time(64'd0),.s_data(32'd0),.s_tag(16'd0),.s_valid(1'b0),
  .m_ready(1'b1),.now(now));
 av_rmii_rx receiver(clk,rst_n,crs,rxd,pending,len0,len1,
  state==RELEASE,bank,bank,address,q,rx_good,rx_bad,rx_overflow);
 assign m_valid=rst_n&&state==OFFER;
 assign m_keep=1'b1;
 assign m_last=address==length-1'b1;
 assign m_user={timestamp,frame_seq};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;bank<=0;address<=0;length<=0;
   frame_seq<=0;timestamp<=0;m_data<=0;delivered_frames<=0;delivered_bytes<=0;end
  else case(state)
   IDLE:if(pending!=0)begin
    bank<=!pending[0];length<=(pending[0]?len0:len1)-4;
    address<=0;frame_seq<=delivered_frames;timestamp<=now;state<=FETCH;
   end
   FETCH:state<=LATCH;
   LATCH:begin m_data<=q;state<=OFFER;end
   OFFER:if(m_ready)begin
    delivered_bytes<=delivered_bytes+1'b1;
    if(m_last)begin delivered_frames<=delivered_frames+1'b1;state<=RELEASE;end
    else begin address<=address+1'b1;state<=FETCH;end
   end
   RELEASE:state<=IDLE;
  endcase
 end
endmodule

