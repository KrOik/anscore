// Single-scale, single-linearization dense Lucas-Kanade. No hidden host math.
module dense_lucas_kanade #(
 parameter integer WIDTH=16,HEIGHT=16,BITS=8,WINDOW=3,FRAC=8,OUT_BITS=24
)(
 input wire clk,rst_n,ce,
 input wire [BITS-1:0] s_prev,s_curr,
 input wire s_valid,s_sof,s_eol,
 output wire s_ready,
 input wire [63:0] texture_threshold,
 output reg signed [OUT_BITS-1:0] m_u,m_v,
 output reg m_flow_valid,m_valid,m_sof,m_eol,
 input wire m_ready,
 output wire busy,
 output reg done,
 output reg [3:0] error_code
);
 localparam [63:0] N64=64'(WIDTH)*64'(HEIGHT);
 localparam integer N=(N64>=1 && N64<=65536)?N64:1;
 localparam integer AW=(N<=1)?1:$clog2(N),R=WINDOW/2,NW=2*BITS+7,DW=2*NW+1,QW=DW+FRAC;
 initial if(WIDTH<1 || HEIGHT<1 || WIDTH>4096 || HEIGHT>4096 || N64>65536 || BITS<8 || BITS>12 ||
  (WINDOW!=3 && WINDOW!=5) || FRAC<0 || FRAC>16 || OUT_BITS<FRAC+2 || OUT_BITS>32)
  $fatal(1,"invalid optical flow parameters");
 reg [BITS-1:0] prev_mem[0:N-1],curr_mem[0:N-1];
 reg [AW-1:0] rd_addr;
 reg [BITS-1:0] pq,cq;
 localparam CAP=0,PIX=1,ADDR=2,READ=3,SAVE=4,MUL=5,DET0=6,DET1=7,NU0=8,NU1=9,NV0=10,NV1=11,
  CHECK=12,PREPU=13,DIVU=14,PREPV=15,DIVV=16,EMIT=17;
 reg [4:0] state;
 reg [11:0] x,y;
 reg [16:0] capture_count;
 reg [2:0] wx,wy,sample_sel,mul_sel;
 reg active;
 reg [63:0] threshold_q;
 reg [BITS-1:0] left_p,right_p,up_p,down_p,center_p,center_c;
 reg signed [NW-1:0] gx,gy,gt;
 reg signed [NW-1:0] a,b,c,d,e,ma,mb;
 wire signed [2*NW-1:0] product=ma*mb;
 reg signed [DW-1:0] temp,det,num_u,num_v;
 reg [QW-1:0] quotient;
 reg [DW:0] rem_q;
 reg [7:0] div_count;
 reg negative_q;
 wire [DW:0] trial={rem_q[DW-1:0],quotient[QW-1]};
 wire take=trial>={1'b0,det[DW-1:0]};
 wire [QW-1:0] next_q={quotient[QW-2:0],take};
 wire [QW-1:0] limit_pos=({{(QW-1){1'b0}},1'b1}<<(OUT_BITS-1))-1'b1;
 wire [QW-1:0] limit_neg=({{(QW-1){1'b0}},1'b1}<<(OUT_BITS-1));
 wire overflow=next_q>(negative_q?limit_neg:limit_pos);
 integer sx,sy,addr_calc;
 always @* begin
  sx=$signed({1'b0,x})+$signed({1'b0,wx})-R;
  sy=$signed({1'b0,y})+$signed({1'b0,wy})-R;
  case(sample_sel)
   0:addr_calc=sy*WIDTH+sx-1;
   1:addr_calc=sy*WIDTH+sx+1;
   2:addr_calc=(sy-1)*WIDTH+sx;
   3:addr_calc=(sy+1)*WIDTH+sx;
   default:addr_calc=sy*WIDTH+sx;
  endcase
  ma=0;mb=0;
  if(state==MUL)case(mul_sel)
   0:begin ma=gx;mb=gx;end
   1:begin ma=gx;mb=gy;end
   2:begin ma=gy;mb=gy;end
   3:begin ma=gx;mb=gt;end
   4:begin ma=gy;mb=gt;end
  endcase
  else case(state)
   DET0:begin ma=a;mb=c;end
   DET1:begin ma=b;mb=b;end
   NU0:begin ma=b;mb=e;end
   NU1:begin ma=c;mb=d;end
   NV0:begin ma=b;mb=d;end
   NV1:begin ma=a;mb=e;end
  endcase
 end
 assign s_ready=state==CAP;
 assign busy=active || state!=CAP;
 // True synchronous read ports; no combinational array indexing in datapath.
 always @(posedge clk) if(ce)begin
  if(state==CAP && rst_n && s_valid && s_ready)begin
   prev_mem[capture_count[AW-1:0]]<=s_prev;curr_mem[capture_count[AW-1:0]]<=s_curr;
  end
  if(state==READ)begin pq<=prev_mem[rd_addr];cq<=curr_mem[rd_addr];end
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=CAP;x<=0;y<=0;capture_count<=0;active<=0;threshold_q<=0;
   wx<=0;wy<=0;sample_sel<=0;mul_sel<=0;rd_addr<=0;
   a<=0;b<=0;c<=0;d<=0;e<=0;gx<=0;gy<=0;gt<=0;
   temp<=0;det<=0;num_u<=0;num_v<=0;quotient<=0;rem_q<=0;div_count<=0;negative_q<=0;
   left_p<=0;right_p<=0;up_p<=0;down_p<=0;center_p<=0;center_c<=0;
   m_u<=0;m_v<=0;m_flow_valid<=0;m_valid<=0;m_sof<=0;m_eol<=0;done<=0;error_code<=0;
  end else if(ce)begin
   done<=0;
   case(state)
    CAP:if(s_valid)begin
     if(s_sof!=(x==0 && y==0) || s_eol!=(x==WIDTH-1))begin
      x<=0;y<=0;capture_count<=0;active<=0;done<=1;error_code<=1;
     end else begin
      if(!active)begin active<=1;threshold_q<=texture_threshold;error_code<=0;end
      if(capture_count==N-1)begin state<=PIX;capture_count<=0;x<=0;y<=0;end
      else begin
       capture_count<=capture_count+1'b1;
       if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
      end
     end
    end
    PIX:begin
     m_u<=0;m_v<=0;m_flow_valid<=0;m_sof<=(x==0 && y==0);m_eol<=(x==WIDTH-1);
     if(x<R+1 || y<R+1 || x+R+1>=WIDTH || y+R+1>=HEIGHT)begin m_valid<=1;state<=EMIT;end
     else begin a<=0;b<=0;c<=0;d<=0;e<=0;wx<=0;wy<=0;sample_sel<=0;state<=ADDR;end
    end
    ADDR:begin rd_addr<=addr_calc[AW-1:0];state<=READ;end
    READ:state<=SAVE;
    SAVE:begin
     case(sample_sel)
      0:left_p<=pq;
      1:right_p<=pq;
      2:up_p<=pq;
      3:down_p<=pq;
      4:begin
       center_p<=pq;center_c<=cq;
       gx<=$signed({1'b0,right_p})-$signed({1'b0,left_p});
       gy<=$signed({1'b0,down_p})-$signed({1'b0,up_p});
       gt<=($signed({1'b0,cq})-$signed({1'b0,pq}))*2;
      end
     endcase
     if(sample_sel==4)begin mul_sel<=0;state<=MUL;end
     else begin sample_sel<=sample_sel+1'b1;state<=ADDR;end
    end
    MUL:begin
     case(mul_sel)
      0:a<=a+product;
      1:b<=b+product;
      2:c<=c+product;
      3:d<=d+product;
      4:e<=e+product;
     endcase
     if(mul_sel==4)begin
      if(wx==WINDOW-1 && wy==WINDOW-1)state<=DET0;
      else begin
       if(wx==WINDOW-1)begin wx<=0;wy<=wy+1'b1;end else wx<=wx+1'b1;
       sample_sel<=0;state<=ADDR;
      end
     end else mul_sel<=mul_sel+1'b1;
    end
    DET0:begin temp<=product;state<=DET1;end
    DET1:begin det<=temp-product;state<=NU0;end
    NU0:begin temp<=product;state<=NU1;end
    NU1:begin num_u<=temp-product;state<=NV0;end
    NV0:begin temp<=product;state<=NV1;end
    NV1:begin num_v<=temp-product;state<=CHECK;end
    CHECK:begin
     if(det<=0 || $unsigned(det)<=threshold_q)begin m_valid<=1;state<=EMIT;end
     else state<=PREPU;
    end
    PREPU:begin
     quotient<=(num_u<0 ? {{FRAC{1'b0}},$unsigned(-num_u)} : {{FRAC{1'b0}},$unsigned(num_u)})<<FRAC;
     rem_q<=0;div_count<=0;negative_q<=num_u<0;state<=DIVU;m_flow_valid<=1;
    end
    DIVU,DIVV:begin
     quotient<=next_q;rem_q<=take?trial-{1'b0,det[DW-1:0]}:trial;
     if(div_count==QW-1)begin
      if(overflow)begin m_flow_valid<=0;m_u<=0;m_v<=0;m_valid<=1;state<=EMIT;end
      else if(state==DIVU)begin m_u<=negative_q ? -$signed(next_q[OUT_BITS-1:0]) : $signed(next_q[OUT_BITS-1:0]);state<=PREPV;end
      else begin m_v<=negative_q ? -$signed(next_q[OUT_BITS-1:0]) : $signed(next_q[OUT_BITS-1:0]);m_valid<=1;state<=EMIT;end
     end else div_count<=div_count+1'b1;
    end
    PREPV:begin
     quotient<=(num_v<0 ? {{FRAC{1'b0}},$unsigned(-num_v)} : {{FRAC{1'b0}},$unsigned(num_v)})<<FRAC;
     rem_q<=0;div_count<=0;negative_q<=num_v<0;state<=DIVV;
    end
    EMIT:if(m_ready)begin
     m_valid<=0;
     if(x==WIDTH-1 && y==HEIGHT-1)begin x<=0;y<=0;active<=0;done<=1;state<=CAP;end
     else begin if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=PIX;end
    end
    default:begin state<=CAP;x<=0;y<=0;capture_count<=0;active<=0;m_valid<=0;done<=1;error_code<=2;end
   endcase
  end
 end
endmodule
