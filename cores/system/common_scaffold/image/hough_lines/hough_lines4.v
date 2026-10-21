// Four-angle discrete line Hough transform, synchronous accumulator RAM.
module hough_lines4 #(parameter WIDTH=64,HEIGHT=48,COUNT_W=16)(
 input wire clk,rst,ce,input wire s_edge,s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output wire[1:0] m_theta,
 output wire signed[((WIDTH+HEIGHT-2<1)?1:$clog2(WIDTH+HEIGHT-1)+1)-1:0] m_rho,
 output wire[COUNT_W-1:0] m_count,output wire m_last,
 output wire peak_valid,input wire peak_ready,output reg[1:0] peak_theta,
 output reg signed[((WIDTH+HEIGHT-2<1)?1:$clog2(WIDTH+HEIGHT-1)+1)-1:0] peak_rho,
 output reg[COUNT_W-1:0] peak_count,output reg overflow,marker_error,output wire busy
);
 localparam MAXR=WIDTH+HEIGHT-2,BINS=2*MAXR+1,TOTAL=4*BINS;
 localparam AW=TOTAL<2?1:$clog2(TOTAL),XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT),RW=MAXR<1?1:$clog2(MAXR+1)+1;
 localparam CLEAR=0,INPUT=1,VADDR=2,VREAD=3,VWRITE=4,OREAD=5,OHOLD=6,PEAK=7;
 reg[2:0] state;reg[AW-1:0] clear_addr,vote_addr,out_addr;
 reg[XW-1:0] x,vote_x;reg[YW-1:0] y,vote_y;
 reg[1:0] theta,out_theta;reg signed[RW-1:0] out_rho;reg frame_end;
 reg[COUNT_W-1:0] memory[0:TOTAL-1],read_q;
 wire[AW-1:0] read_addr=state==VREAD?vote_addr:out_addr;
 function integer rho;
 input[1:0] angle;input integer px,py;
 begin case(angle)
 0:rho=px;
 1:rho=(181*(px+py)+128)>>>8;
 2:rho=py;
 default:rho=(181*(py-px)+128)>>>8;
 endcase end
 endfunction
 always @(posedge clk) if(ce&&!rst) begin
 if(state==CLEAR)memory[clear_addr]<=0;
 else if(state==VWRITE&&read_q!={COUNT_W{1'b1}})memory[vote_addr]<=read_q+1'b1;
 if(state==VREAD||state==OREAD)read_q<=memory[read_addr];
 end
 assign s_ready=!rst&&ce&&state==INPUT;
 assign m_valid=!rst&&state==OHOLD;
 assign m_theta=out_theta;assign m_rho=out_rho;assign m_count=read_q;assign m_last=m_valid&&out_addr==TOTAL-1;
 assign peak_valid=!rst&&state==PEAK;
 assign busy=state!=INPUT||x!=0||y!=0;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||COUNT_W<1||COUNT_W>24)$fatal(1,"invalid Hough parameters");
 always @(posedge clk) begin
 if(rst) begin
 state<=CLEAR;clear_addr<=0;vote_addr<=0;out_addr<=0;x<=0;y<=0;vote_x<=0;vote_y<=0;theta<=0;out_theta<=0;out_rho<=-MAXR;frame_end<=0;
 peak_theta<=0;peak_rho<=-MAXR;peak_count<=0;overflow<=0;marker_error<=0;
 end else if(ce)case(state)
 CLEAR: begin
 if(clear_addr==0)begin overflow<=0;marker_error<=0;peak_count<=0;peak_theta<=0;peak_rho<=-MAXR;end
 if(clear_addr==TOTAL-1)begin clear_addr<=0;state<=INPUT;end else clear_addr<=clear_addr+1'b1;
 end
 INPUT: if(s_valid&&s_ready) begin
 if(s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1))marker_error<=1;
 frame_end<=x==WIDTH-1&&y==HEIGHT-1;
 if(x==WIDTH-1)begin x<=0;if(y==HEIGHT-1)y<=0;else y<=y+1'b1;end else x<=x+1'b1;
 if(s_edge)begin vote_x<=x;vote_y<=y;theta<=0;state<=VADDR;end
 else if(x==WIDTH-1&&y==HEIGHT-1)begin out_addr<=0;out_theta<=0;out_rho<=-MAXR;state<=OREAD;end
 end
 VADDR:begin vote_addr<=theta*BINS+rho(theta,vote_x,vote_y)+MAXR;state<=VREAD;end
 VREAD:state<=VWRITE;
 VWRITE:begin
 if(read_q=={COUNT_W{1'b1}})overflow<=1;
 if(theta==3)begin
 if(frame_end)begin out_addr<=0;out_theta<=0;out_rho<=-MAXR;state<=OREAD;end else state<=INPUT;
 end else begin theta<=theta+1'b1;state<=VADDR;end
 end
 OREAD:state<=OHOLD;
 OHOLD:if(m_ready)begin
 if(read_q>peak_count)begin peak_count<=read_q;peak_theta<=out_theta;peak_rho<=out_rho;end
 if(out_addr==TOTAL-1)state<=PEAK;
 else begin
 out_addr<=out_addr+1'b1;state<=OREAD;
 if(out_rho==MAXR)begin out_rho<=-MAXR;out_theta<=out_theta+1'b1;end else out_rho<=out_rho+1'b1;
 end
 end
 PEAK:if(peak_ready)begin clear_addr<=0;state<=CLEAR;end
 default:state<=CLEAR;
 endcase
 end
endmodule
