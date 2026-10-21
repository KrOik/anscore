// Brown-Conrady rectified-output -> distorted-source coordinate generator.
module lens_distortion_map #(
 parameter WIDTH=16,HEIGHT=12,SRC_WIDTH=WIDTH,SRC_HEIGHT=HEIGHT
)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,
 input wire signed [31:0] cfg_fx,cfg_fy,cfg_cx,cfg_cy,
 input wire signed [31:0] cfg_invfx,cfg_invfy,
 input wire signed [31:0] cfg_k1,cfg_k2,cfg_k3,cfg_p1,cfg_p2,
 output reg cfg_done,cfg_error,output reg [3:0] error_code,
 input wire start_valid,output wire start_ready,
 output reg signed [31:0] m_src_x,m_src_y,
 output wire [15:0] m_x,m_y,output reg m_oob,m_overflow,
 output reg m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output wire busy
);
 localparam IDLE=0,INIT=1,ISSUE=2,MULTIPLY=3,ROUND=4,HOLD=5,DONE=6;
 reg [2:0] state;
 reg configured;
 reg signed [31:0] fx,fy,cx,cy,invfx,invfy,k1,k2,k3,p1,p2;
 reg signed [31:0] r[0:12];
 reg [15:0] x,y;
 reg [5:0] pc;
 reg [3:0] target;
 reg shift30,negative,pixel_overflow;
 reg [63:0] product,multiplicand;
 reg [31:0] multiplier;
 reg [4:0] mul_bit;
 wire valid_config=cfg_fx>=32'sd65536&&cfg_fy>=32'sd65536&&cfg_fx<=32'sd536870912&&cfg_fy<=32'sd536870912&&
  cfg_invfx>0&&cfg_invfy>0&&cfg_invfx<=32'sd1073741824&&cfg_invfy<=32'sd1073741824&&
  cfg_cx>=-32'sd536870912&&cfg_cx<=32'sd536870912&&cfg_cy>=-32'sd536870912&&cfg_cy<=32'sd536870912;
 wire [63:0] rounded=shift30?(product+64'd536870912)>>30:(product+64'd32768)>>16;
 wire multiply_overflow=rounded>(negative?64'd2147483648:64'd2147483647);
 assign cfg_ready=rst_n&&ce&&state==IDLE;
 assign start_ready=rst_n&&ce&&state==IDLE&&!cfg_valid;
 assign m_x=x;assign m_y=y;
 assign m_sof=m_valid&&x==0&&y==0;assign m_eol=m_valid&&x==WIDTH-1;
 assign m_last=m_valid&&x==WIDTH-1&&y==HEIGHT-1;
 assign done_valid=rst_n&&state==DONE;assign busy=state!=IDLE;
 task mul;
 input signed [31:0] a,b;input [3:0] destination;input use30;
 begin
  multiplicand<={32'b0,(a[31]?-a:a)};multiplier<=b[31]?-b:b;
  product<=0;negative<=a[31]^b[31];mul_bit<=0;target<=destination;shift30<=use30;state<=MULTIPLY;
 end
 endtask
 task add;
 input signed [31:0] a,b;input [3:0] destination;reg signed [32:0] total;
 begin
  total=$signed({a[31],a})+$signed({b[31],b});
  if(total>33'sd2147483647)begin r[destination]<=32'sh7fffffff;pixel_overflow<=1;end
  else if(total< -33'sd2147483648)begin r[destination]<=32'sh80000000;pixel_overflow<=1;end
  else r[destination]<=total[31:0];
  pc<=pc+1'b1;
 end
 endtask
 initial if(WIDTH<1||HEIGHT<1||SRC_WIDTH<1||SRC_HEIGHT<1||WIDTH>4096||HEIGHT>4096||SRC_WIDTH>4096||SRC_HEIGHT>4096)$fatal(1,"invalid lens distortion geometry");
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;configured<=0;fx<=0;fy<=0;cx<=0;cy<=0;invfx<=0;invfy<=0;k1<=0;k2<=0;k3<=0;p1<=0;p2<=0;
   x<=0;y<=0;pc<=0;target<=0;shift30<=0;negative<=0;pixel_overflow<=0;product<=0;multiplicand<=0;multiplier<=0;mul_bit<=0;
   cfg_done<=0;cfg_error<=0;error_code<=0;m_src_x<=0;m_src_y<=0;m_oob<=0;m_overflow<=0;m_valid<=0;
  end else if(ce)begin
   cfg_done<=0;cfg_error<=0;
   case(state)
    IDLE:begin
     if(cfg_valid)begin
      cfg_done<=1;
      if(!valid_config)begin cfg_error<=1;error_code<=2;end
      else begin
       fx<=cfg_fx;fy<=cfg_fy;cx<=cfg_cx;cy<=cfg_cy;invfx<=cfg_invfx;invfy<=cfg_invfy;
       k1<=cfg_k1;k2<=cfg_k2;k3<=cfg_k3;p1<=cfg_p1;p2<=cfg_p2;configured<=1;error_code<=0;
      end
     end else if(start_valid)begin
      if(!configured)error_code<=1;
      else begin x<=0;y<=0;state<=INIT;end
     end
    end
    INIT:begin pc<=0;pixel_overflow<=0;state<=ISSUE;end
    ISSUE:case(pc)
     0:add($signed({x,16'b0}),-cx,12);
     1:mul(r[12],invfx,0,1);
     2:add($signed({y,16'b0}),-cy,12);
     3:mul(r[12],invfy,1,1);
     4:mul(r[0],r[0],2,0);
     5:mul(r[1],r[1],3,0);
     6:mul(r[0],r[1],4,0);
     7:add(r[2],r[3],5);
     8:mul(k3,r[5],6,0);
     9:add(r[6],k2,6);
     10:mul(r[6],r[5],6,0);
     11:add(r[6],k1,6);
     12:mul(r[6],r[5],6,0);
     13:add(r[6],32'sd65536,6);
     14:mul(r[0],r[6],7,0);
     15:mul(r[1],r[6],8,0);
     16:mul(p1,r[4],9,0);
     17:add(r[9],r[9],9);
     18:add(r[7],r[9],7);
     19:add(r[2],r[2],9);
     20:add(r[5],r[9],9);
     21:mul(p2,r[9],9,0);
     22:add(r[7],r[9],7);
     23:mul(p2,r[4],9,0);
     24:add(r[9],r[9],9);
     25:add(r[8],r[9],8);
     26:add(r[3],r[3],9);
     27:add(r[5],r[9],9);
     28:mul(p1,r[9],9,0);
     29:add(r[8],r[9],8);
     30:mul(fx,r[7],10,0);
     31:add(r[10],cx,10);
     32:mul(fy,r[8],11,0);
     33:add(r[11],cy,11);
     default:begin
      m_src_x<=r[10];m_src_y<=r[11];m_overflow<=pixel_overflow;
      m_oob<=r[10]<0||r[11]<0||r[10]>(SRC_WIDTH-1)*65536||r[11]>(SRC_HEIGHT-1)*65536;
      m_valid<=1;state<=HOLD;
     end
    endcase
    MULTIPLY:begin
     if(multiplier[0])product<=product+multiplicand;
     multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
     if(mul_bit==31)state<=ROUND;else mul_bit<=mul_bit+1'b1;
    end
    ROUND:begin
     if(multiply_overflow)begin r[target]<=negative?32'sh80000000:32'sh7fffffff;pixel_overflow<=1;end
     else r[target]<=negative?-rounded[31:0]:rounded[31:0];
     pc<=pc+1'b1;state<=ISSUE;
    end
    HOLD:if(m_ready)begin
     m_valid<=0;
     if(x==WIDTH-1&&y==HEIGHT-1)state<=DONE;
     else begin if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=INIT;end
    end
    DONE:if(done_ready)state<=IDLE;
    default:begin m_valid<=0;state<=IDLE;configured<=0;error_code<=3;end
   endcase
  end
 end
endmodule
