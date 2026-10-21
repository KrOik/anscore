// Original Malvar-He-Cutler 5x5 linear demosaicing, REFLECT101 boundary.
module malvar_demosaic #(
 parameter integer WIDTH=32,HEIGHT=24,BITS=8
)(input wire clk,rst_n,ce,input wire start_valid,output wire start_ready,
 input wire[1:0] cfg_pattern,input wire abort,
 input wire[BITS-1:0] s_data,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output wire[3*BITS-1:0] m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[7:0] error_code,output wire busy);
 localparam integer N=(WIDTH>0&&HEIGHT>0)?WIDTH*HEIGHT:1,AW=$clog2(N+1),ACC=BITS+7;
 localparam IDLE=0,CAP=1,PREP=2,READ=3,MAC=4,ROUND=5,HOLD=6,DONE=7;
 reg[2:0]state;reg[1:0] pattern;reg[AW-1:0]in_pos,out_pos;reg[15:0] in_x,out_x,out_y;
 reg[BITS-1:0] frame[0:N-1],sample_q,center;
 reg[4:0]tap;reg signed[ACC-1:0] a_g,a_h,a_v,a_c;
 reg[3*BITS-1:0]out_q;
 wire is_red=(out_y[0]==pattern[1]&&out_x[0]==pattern[0]);
 wire is_blue=(out_y[0]!=pattern[1]&&out_x[0]!=pattern[0]);
 wire red_row=out_y[0]==pattern[1];
 function integer reflect101;input integer index,length;integer q,j;begin
 q=index;if(length<=1)reflect101=0;else begin
 for(j=0;j<4;j=j+1)begin if(q<0)q=-q;else if(q>=length)q=2*length-2-q;end
 reflect101=q;end end endfunction
 wire[31:0] read_x=reflect101($signed({1'b0,out_x})+$signed(tap%5)-2,WIDTH);
 wire[31:0] read_y=reflect101($signed({1'b0,out_y})+$signed(tap/5)-2,HEIGHT);
 function signed[5:0] kg;input[4:0] i;begin case(i)
 2,10,14,22:kg=-2;7,11,13,17:kg=4;12:kg=8;default:kg=0;endcase end endfunction
 function signed[5:0] kh;input[4:0]i;begin case(i)
 2,22:kh=1;6,8,10,14,16,18:kh=-2;11,13:kh=8;12:kh=10;default:kh=0;endcase end endfunction
 function signed[5:0] kv;input[4:0]i;begin kv=kh((i%5)*5+i/5);end endfunction
 function signed[5:0] kc;input[4:0]i;begin case(i)
 2,10,14,22:kc=-3;6,8,16,18:kc=4;12:kc=12;default:kc=0;endcase end endfunction
 function signed[ACC-1:0] weighted;input[BITS-1:0] value;input signed[5:0] w;reg signed[ACC-1:0]v;begin
 v=$signed({1'b0,value});case(w)
 -3:weighted=-(v+(v<<1));-2:weighted=-(v<<1);1:weighted=v;4:weighted=v<<2;8:weighted=v<<3;
 10:weighted=(v<<3)+(v<<1);12:weighted=(v<<3)+(v<<2);default:weighted=0;endcase end endfunction
 function[BITS-1:0] quantize;input signed[ACC-1:0]v;reg signed[ACC-1:0]q;begin
 q=(v+8)>>>4;if(q<0)quantize=0;else if(q>((1<<BITS)-1))quantize={BITS{1'b1}};else quantize=q[BITS-1:0];end endfunction
 assign start_ready=rst_n&&ce&&!abort&&state==IDLE;
 assign s_ready=rst_n&&ce&&!abort&&state==CAP;
 assign m_valid=state==HOLD&&!abort;assign m_data=out_q;
 assign m_sof=out_pos==0;assign m_eol=out_x==WIDTH-1;assign m_last=out_pos==N-1;
 assign done_valid=state==DONE;assign busy=state!=IDLE&&state!=DONE;
 task fail;input[7:0]code;begin state<=DONE;done_error<=1;error_code<=code;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;done_error<=0;error_code<=0;in_pos<=0;out_pos<=0;in_x<=0;out_x<=0;out_y<=0;pattern<=0;end
 else if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE)fail(8'h93);
 else case(state)
 IDLE:if(start_valid&&!abort)begin
 done_error<=0;error_code<=0;in_pos<=0;out_pos<=0;in_x<=0;out_x<=0;out_y<=0;pattern<=cfg_pattern;
 if(WIDTH<1||HEIGHT<1||WIDTH>256||HEIGHT>256||(BITS!=8&&BITS!=10&&BITS!=12))fail(8'h80);else state<=CAP;end
 CAP:if(s_valid)begin
 if(s_sof!=(in_pos==0)||s_eol!=(in_x==WIDTH-1)||s_last!=(in_pos==N-1))fail(8'h81);
 else begin frame[in_pos]<=s_data;
 if(in_pos==N-1)state<=PREP;else begin in_pos<=in_pos+1;if(in_x==WIDTH-1)in_x<=0;else in_x<=in_x+1;end end end
 PREP:begin a_g<=0;a_h<=0;a_v<=0;a_c<=0;tap<=0;state<=READ;end
 READ:begin sample_q<=frame[read_y*WIDTH+read_x];state<=MAC;end
 MAC:begin a_g<=a_g+weighted(sample_q,kg(tap));a_h<=a_h+weighted(sample_q,kh(tap));
 a_v<=a_v+weighted(sample_q,kv(tap));a_c<=a_c+weighted(sample_q,kc(tap));
 if(tap==12)center<=sample_q;
 if(tap==24)state<=ROUND;else begin tap<=tap+1;state<=READ;end end
 ROUND:begin
 if(is_red)out_q<={center,quantize(a_g),quantize(a_c)};
 else if(is_blue)out_q<={quantize(a_c),quantize(a_g),center};
 else if(red_row)out_q<={quantize(a_h),center,quantize(a_v)};
 else out_q<={quantize(a_v),center,quantize(a_h)};state<=HOLD;end
 HOLD:if(m_ready)begin if(out_pos==N-1)state<=DONE;
 else begin out_pos<=out_pos+1;if(out_x==WIDTH-1)begin out_x<=0;out_y<=out_y+1;end else out_x<=out_x+1;state<=PREP;end end
 DONE:if(done_ready)state<=IDLE;default:fail(8'h94);
 endcase end end
endmodule
