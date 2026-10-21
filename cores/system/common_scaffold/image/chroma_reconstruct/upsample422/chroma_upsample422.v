// Line-buffered 4:2:2 to 4:4:4 reconstruction. See README.md.
module chroma_upsample422 #(parameter BITS=8, WIDTH=640, HEIGHT=480)(
 input wire clk,rst,ce,
 input wire cfg_valid, input wire [1:0] cfg_siting, input wire cfg_linear,
 output wire cfg_ready, output reg cfg_error,
 input wire [4*BITS-1:0] s_tdata,input wire s_tvalid,s_tuser,s_tlast,output wire s_tready,
 output wire [3*BITS-1:0] m_tdata,output wire m_tvalid,m_tuser,m_tlast,input wire m_tready,
 output reg busy,output reg marker_error
);
 localparam PAIRS=(WIDTH+1)/2;
 localparam CW=(PAIRS<2)?1:$clog2(PAIRS), XW=(WIDTH<2)?1:$clog2(WIDTH),YW=(HEIGHT<2)?1:$clog2(HEIGHT);
 localparam CAP=0,PREV=1,CUR=2,NEXT=3,EMIT=4,LATCH=5;
 reg [2:0] state;
 reg [4*BITS-1:0] mem[0:PAIRS-1];
 reg [4*BITS-1:0] p,c,n;
 reg [CW-1:0] wr,rd;
 reg [4*BITS-1:0] read_q;
 wire [CW-1:0] read_addr=(state==PREV)?((rd==0)?rd:rd-1'b1):(state==NEXT)?((rd==PAIRS-1)?rd:rd+1'b1):rd;
 always @(posedge clk) if(ce) read_q<=mem[read_addr];

 reg [XW-1:0] x;
 reg [YW-1:0] y;
 reg siting,linear;
 wire in_fire=ce&&s_tready&&s_tvalid;
 wire out_fire=ce&&m_tvalid&&m_tready;
 assign cfg_ready=ce&&!busy&&state==CAP&&wr==0;
 assign s_tready=ce&&state==CAP&&!(cfg_valid&&!busy);
 assign m_tvalid=state==EMIT;
 assign m_tuser=m_tvalid&&x==0&&y==0;
 assign m_tlast=m_tvalid&&x==WIDTH-1;
 function [BITS-1:0] interp;
 input [BITS-1:0] a,b,d;
 input odd;
 reg [BITS+1:0] sum;
 begin
 if(!linear) interp=(!siting&&odd)?d:b;
 else if(!siting) begin
 if(!odd) interp=b;
 else begin sum={2'b0,b}+{2'b0,d}+1; interp=sum>>1; end
 end else begin
 if(odd) sum=({2'b0,b}<<1)+b+d+2;
 else sum=({2'b0,b}<<1)+b+a+2;
 interp=sum>>2;
 end
 end
 endfunction
 assign m_tdata={x[0]?c[2*BITS-1:BITS]:c[4*BITS-1:3*BITS],
 interp(p[3*BITS-1:2*BITS],c[3*BITS-1:2*BITS],n[3*BITS-1:2*BITS],x[0]),
 interp(p[BITS-1:0],c[BITS-1:0],n[BITS-1:0],x[0])};
 initial begin
 if((BITS!=8&&BITS!=10)||WIDTH<1||HEIGHT<1) $fatal(1,"invalid parameters");
 end
 always @(posedge clk) begin
 if(rst) begin state<=CAP;wr<=0;rd<=0;x<=0;y<=0;busy<=0;marker_error<=0;cfg_error<=0;siting<=0;linear<=1;p<=0;c<=0;n<=0;end
 else if(ce) begin
 if(cfg_valid&&cfg_ready) begin
 if(cfg_siting>1) cfg_error<=1;
 else begin siting<=cfg_siting[0];linear<=cfg_linear;end
 end
 if(in_fire) begin
 mem[wr]<=s_tdata;busy<=1;
 if(s_tuser!=(wr==0&&y==0)||s_tlast!=(wr==PAIRS-1)) marker_error<=1;
 if(wr==PAIRS-1) begin wr<=0;rd<=0;x<=0;state<=PREV;end
 else wr<=wr+1'b1;
 end
 case(state)
 PREV: state<=CUR;
 CUR: begin p<=read_q;state<=NEXT;end
 NEXT: begin c<=read_q;state<=LATCH;end
 LATCH: begin n<=read_q;state<=EMIT;end
 EMIT: if(out_fire) begin
 if(x==WIDTH-1) begin state<=CAP;x<=0;if(y==HEIGHT-1) begin y<=0;busy<=0;end else y<=y+1'b1;end
 else begin x<=x+1'b1;if(x[0]) begin rd<=rd+1'b1;state<=PREV;end end
 end
 default: ;
 endcase
 end
 end
endmodule

