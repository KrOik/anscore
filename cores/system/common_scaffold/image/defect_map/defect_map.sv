// Static calibration map correction. Original source samples only; exhaustive nearest phase search.
module defect_map #(
 parameter integer WIDTH=16,HEIGHT=12,BITS=12,
 parameter integer N=WIDTH*HEIGHT,AW=$clog2(N+1)
)(input clk,rst_n,ce,
 input cfg_begin_valid,output cfg_begin_ready,
 input [AW-1:0] cfg_index,input cfg_bad,input cfg_valid,output cfg_ready,
 input cfg_commit_valid,output cfg_commit_ready,input cfg_abort,
 output cfg_done_valid,input cfg_done_ready,output reg cfg_error,output reg[3:0]cfg_error_code,
 output reg map_active_valid,
 input start_valid,output start_ready,input[1:0]cfg_pattern,input[BITS-1:0]cfg_fill,input abort,
 input[BITS-1:0]s_pixel,input s_valid,s_sof,s_eol,s_last,output s_ready,
 output[BITS-1:0]m_pixel,output m_valid,m_sof,m_eol,m_last,
 output m_repaired,m_unrepaired,m_invalid,output[1:0]m_status,input m_ready,
 output done_valid,input done_ready,output reg frame_error,output reg[3:0]error_code,output busy);
 localparam IDLE=0,CAP=1,TREAD=2,TUSE=3,SREAD=4,SUSE=5,FINAL=6,HOLD=7,DONE=8;
 localparam SW=BITS+AW+1;
 reg[3:0]state;reg[1:0]cstate,pattern;
 reg active_bank,write_bank,frame_bank;
 reg[N-1:0]written;
 (* ram_style="block" *)reg map0[0:N-1];
 (* ram_style="block" *)reg map1[0:N-1];
 (* ram_style="block" *)reg[BITS-1:0]frame[0:N-1];
 reg mask0_q,mask1_q;reg[BITS-1:0]sample_q,fill_q,out_q;
 reg[AW-1:0]in_pos,out_pos,scan_pos;
 reg[8:0]in_x,out_x,out_y,scan_x,scan_y;
 reg[31:0]best_distance;
 reg[SW-1:0]sum;
 reg[AW:0]ties;
 reg repaired_q,invalid_q;
 wire lookup=state==TREAD||state==SREAD;
 wire[AW-1:0]read_addr=state==TREAD?out_pos:scan_pos;
 wire bad_q=frame_bank?mask1_q:mask0_q;
 wire[8:0]dx=out_x>=scan_x?out_x-scan_x:scan_x-out_x;
 wire[8:0]dy=out_y>=scan_y?out_y-scan_y:scan_y-out_y;
 wire[31:0]distance=dx*dx+dy*dy;
 wire same_phase=(out_x[0]==scan_x[0])&&(out_y[0]==scan_y[0]);
 assign cfg_begin_ready=rst_n&&ce&&!cfg_abort&&cstate==0;
 assign cfg_ready=rst_n&&ce&&!cfg_abort&&!cfg_commit_valid&&cstate==1;
 assign cfg_commit_ready=rst_n&&ce&&!cfg_abort&&state==IDLE&&cstate==1;
 assign cfg_done_valid=rst_n&&cstate==2;
 assign start_ready=rst_n&&ce&&!abort&&state==IDLE&&!(cfg_commit_valid&&cfg_commit_ready);
 assign s_ready=rst_n&&ce&&!abort&&state==CAP;
 assign m_valid=rst_n&&!abort&&state==HOLD;
 assign m_pixel=out_q;
 assign m_sof=out_pos==0;assign m_eol=out_x==WIDTH-1;assign m_last=out_pos==N-1;
 assign m_repaired=repaired_q;assign m_unrepaired=invalid_q;assign m_invalid=invalid_q;
 assign m_status=invalid_q?2:repaired_q?1:0;
 assign done_valid=rst_n&&state==DONE;assign busy=state!=IDLE&&state!=DONE;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>256||HEIGHT>256||N!=WIDTH*HEIGHT||AW!=$clog2(N+1)||(BITS!=8&&BITS!=10&&BITS!=12))$fatal(1,"defect_map parameters");
 // Two synchronous map banks, independent inactive write and active read ports.
 always @(posedge clk)if(ce)begin
 if(cfg_valid&&cfg_ready&&cfg_index<N)begin
 if(write_bank)map1[cfg_index]<=cfg_bad;else map0[cfg_index]<=cfg_bad;end
 if(lookup)begin mask0_q<=map0[read_addr];mask1_q<=map1[read_addr];sample_q<=frame[read_addr];end
 if(s_valid&&s_ready)frame[in_pos]<=s_pixel;
 end
 task fail;input[3:0]code;begin state<=DONE;frame_error<=1;error_code<=code;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin
 state<=IDLE;cstate<=0;active_bank<=0;write_bank<=1;frame_bank<=0;map_active_valid<=0;written<=0;
 cfg_error<=0;cfg_error_code<=0;frame_error<=0;error_code<=0;in_pos<=0;out_pos<=0;scan_pos<=0;
 in_x<=0;out_x<=0;out_y<=0;scan_x<=0;scan_y<=0;sum<=0;ties<=0;best_distance<=32'hffffffff;
 repaired_q<=0;invalid_q<=0;out_q<=0;fill_q<=0;pattern<=0;
 end else if(ce)begin
 if(cfg_abort&&cstate==1)begin cstate<=2;cfg_error<=1;cfg_error_code<=3;end
 else case(cstate)
 0:if(cfg_begin_valid&&cfg_begin_ready)begin write_bank<=!active_bank;written<=0;cfg_error<=0;cfg_error_code<=0;cstate<=1;end
 1:begin
 if(cfg_commit_valid&&cfg_commit_ready)begin cstate<=2;
 if(&written)begin active_bank<=write_bank;map_active_valid<=1;end
 else begin cfg_error<=1;cfg_error_code<=1;end end
 else if(cfg_valid&&cfg_ready)begin
 if(cfg_index>=N)begin cstate<=2;cfg_error<=1;cfg_error_code<=2;end
 else written[cfg_index]<=1;end end
 2:if(cfg_done_ready)cstate<=0;
 default:begin cstate<=2;cfg_error<=1;cfg_error_code<=4;end endcase
 if(abort&&state!=IDLE&&state!=DONE)fail(3);
 else case(state)
 IDLE:if(start_valid&&start_ready)begin
 frame_error<=0;error_code<=0;in_pos<=0;out_pos<=0;in_x<=0;out_x<=0;out_y<=0;
 frame_bank<=active_bank;fill_q<=cfg_fill;pattern<=cfg_pattern;
 if(!map_active_valid)fail(2);else state<=CAP;end
 CAP:if(s_valid&&s_ready)begin
 if(s_sof!=(in_pos==0)||s_eol!=(in_x==WIDTH-1)||s_last!=(in_pos==N-1))fail(1);
 else if(in_pos==N-1)state<=TREAD;
 else begin in_pos<=in_pos+1;if(in_x==WIDTH-1)in_x<=0;else in_x<=in_x+1;end end
 TREAD:state<=TUSE;
 TUSE:begin repaired_q<=0;invalid_q<=0;
 if(!bad_q)begin out_q<=sample_q;state<=HOLD;end
 else begin sum<=0;ties<=0;best_distance<=32'hffffffff;scan_pos<=0;scan_x<=0;scan_y<=0;state<=SREAD;end end
 SREAD:state<=SUSE;
 SUSE:begin
 if(!bad_q&&same_phase)begin
 if(distance<best_distance)begin best_distance<=distance;sum<=sample_q;ties<=1;end
 else if(distance==best_distance)begin sum<=sum+sample_q;ties<=ties+1;end end
 if(scan_pos==N-1)state<=FINAL;
 else begin scan_pos<=scan_pos+1;if(scan_x==WIDTH-1)begin scan_x<=0;scan_y<=scan_y+1;end else scan_x<=scan_x+1;state<=SREAD;end end
 FINAL:begin
 if(ties==0)begin out_q<=fill_q;invalid_q<=1;repaired_q<=0;end
 else begin out_q<=(sum+(ties>>1))/ties;invalid_q<=0;repaired_q<=1;end
 state<=HOLD;end
 HOLD:if(m_ready)begin
 if(out_pos==N-1)state<=DONE;
 else begin out_pos<=out_pos+1;if(out_x==WIDTH-1)begin out_x<=0;out_y<=out_y+1;end else out_x<=out_x+1;state<=TREAD;end end
 DONE:if(done_ready)state<=IDLE;
 default:fail(4);
 endcase end end
endmodule
