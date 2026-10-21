// Exact full-range piecewise-linear tone LUT; three-stage elastic II=1 stream.
module raw_gamma #(
 parameter WIDTH=64,HEIGHT=64,BITS=12,OUT_BITS=12,INDEX_BITS=6
)(input clk,rst_n,ce,
 input cfg_begin_valid,output cfg_begin_ready,
 input [INDEX_BITS:0] cfg_index,input [OUT_BITS-1:0] cfg_value,input cfg_valid,output cfg_ready,
 input cfg_commit_valid,output cfg_commit_ready,input cfg_abort,
 output cfg_done_valid,input cfg_done_ready,output reg cfg_error,output reg [3:0] cfg_error_code,output reg table_active_valid,
 input start_valid,output start_ready,input abort,
 input [BITS-1:0] s_pixel,input s_valid,output s_ready,input s_sof,s_eol,s_last,
 output [OUT_BITS-1:0] m_pixel,output m_valid,input m_ready,output m_sof,m_eol,m_last,
 output done_valid,input done_ready,output reg frame_error,output reg [3:0] error_code);
 localparam K=1<<INDEX_BITS,NODES=K+1,MAXIMUM=(1<<BITS)-1,NW=BITS+OUT_BITS+1;
 localparam IDLE=0,FRAME=1,DRAIN=2,DONE=3;
 reg [1:0] state,cstate;
 reg active_bank,write_bank,frame_bank;
 reg [NODES-1:0] written;
 (* ram_style="block" *) reg [OUT_BITS-1:0] bank0[0:NODES-1];
 (* ram_style="block" *) reg [OUT_BITS-1:0] bank1[0:NODES-1];
 reg [OUT_BITS-1:0] left0,right0,left1,right1;
 reg v0,v1,v2;
 reg bank_s0;reg [BITS-1:0] rem_s0;
 reg [2:0] markers0,markers1,markers2;
 reg [NW-1:0] numerator_s1;
 reg [OUT_BITS-1:0] pixel_s2;
 integer pixel,x,y;
 wire ready2=!v2||m_ready;
 wire ready1=!v1||ready2;
 wire ready0=!v0||ready1;
 wire accept=s_valid&&s_ready;
 wire [INDEX_BITS:0] index_in=s_pixel==MAXIMUM?K-1:(s_pixel>>(BITS-INDEX_BITS));
 wire [BITS+INDEX_BITS:0] scaled={s_pixel,{INDEX_BITS{1'b0}}};
 wire [BITS+INDEX_BITS:0] remainder_in=scaled-index_in*MAXIMUM;
 wire [OUT_BITS-1:0] left_selected=bank_s0?left1:left0,right_selected=bank_s0?right1:right0;
 wire [NW-1:0] blend=left_selected*(MAXIMUM-rem_s0)+right_selected*rem_s0;
 wire write0=cfg_valid&&cfg_ready&&!write_bank&&cfg_index<=K;
 wire write1=cfg_valid&&cfg_ready&&write_bank&&cfg_index<=K;
 assign cfg_begin_ready=rst_n&&ce&&!cfg_abort&&cstate==0;
 assign cfg_ready=rst_n&&ce&&!cfg_abort&&!cfg_commit_valid&&cstate==1;
 assign cfg_commit_ready=rst_n&&ce&&!cfg_abort&&state==IDLE&&cstate==1;
 assign cfg_done_valid=rst_n&&cstate==2;
 assign start_ready=rst_n&&ce&&!abort&&state==IDLE&&!(cfg_commit_valid&&cfg_commit_ready);
 assign s_ready=rst_n&&ce&&!abort&&state==FRAME&&ready0;
 assign m_valid=rst_n&&v2&&!abort;
 assign m_pixel=pixel_s2;assign {m_sof,m_eol,m_last}=markers2;
 assign done_valid=rst_n&&state==DONE;
 initial if((BITS!=8&&BITS!=10&&BITS!=12)||(OUT_BITS!=8&&OUT_BITS!=10&&OUT_BITS!=12)||INDEX_BITS<1||INDEX_BITS>8||INDEX_BITS>BITS||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||WIDTH*HEIGHT>65536)$fatal(1,"raw_gamma parameters");
 // True synchronous TDP lookup: port A writes inactive bank or reads left; B reads right.
 always @(posedge clk)if(ce)begin
 if(write0)bank0[cfg_index]<=cfg_value;
 else if(accept)left0<=bank0[index_in];
 if(accept)right0<=bank0[index_in+1];
 if(write1)bank1[cfg_index]<=cfg_value;
 else if(accept)left1<=bank1[index_in];
 if(accept)right1<=bank1[index_in+1];
 end
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;cstate<=0;active_bank<=0;write_bank<=1;frame_bank<=0;table_active_valid<=0;written<=0;cfg_error<=0;cfg_error_code<=0;frame_error<=0;error_code<=0;v0<=0;v1<=0;v2<=0;pixel<=0;x<=0;y<=0;pixel_s2<=0;markers0<=0;markers1<=0;markers2<=0;rem_s0<=0;bank_s0<=0;numerator_s1<=0;end
 else if(ce)begin
 if(cfg_abort&&cstate==1)begin cstate<=2;cfg_error<=1;cfg_error_code<=3;end
 else case(cstate)
 0:if(cfg_begin_valid&&cfg_begin_ready)begin write_bank<=!active_bank;written<=0;cstate<=1;cfg_error<=0;cfg_error_code<=0;end
 1:begin
 if(cfg_commit_valid&&cfg_commit_ready)begin
 cstate<=2;
 if(!(&written))begin cfg_error<=1;cfg_error_code<=1;end
 else begin active_bank<=write_bank;table_active_valid<=1;cfg_error<=0;cfg_error_code<=0;end
 end else if(cfg_valid&&cfg_ready)begin
 if(cfg_index>K)begin cstate<=2;cfg_error<=1;cfg_error_code<=2;end else written[cfg_index]<=1;
 end end
 2:if(cfg_done_ready)cstate<=0;
 endcase
 if(abort&&(state==FRAME||state==DRAIN))begin state<=DONE;frame_error<=1;error_code<=3;v0<=0;v1<=0;v2<=0;end
 else if(state==FRAME||state==DRAIN)begin
 if(ready2)begin v2<=v1;if(v1)begin pixel_s2<=numerator_s1/MAXIMUM;markers2<=markers1;end end
 if(ready1)begin v1<=v0;if(v0)begin numerator_s1<=blend+(MAXIMUM/2);markers1<=markers0;end end
 if(ready0)begin v0<=accept;if(accept)begin bank_s0<=frame_bank;rem_s0<=remainder_in[BITS-1:0];markers0<={s_sof,s_eol,s_last};end end
 if(accept)begin
 if(s_sof!=(pixel==0)||s_eol!=(x==WIDTH-1)||s_last!=(pixel==WIDTH*HEIGHT-1))begin state<=DONE;frame_error<=1;error_code<=1;v0<=0;v1<=0;v2<=0;end
 else if(pixel==WIDTH*HEIGHT-1)state<=DRAIN;
 else begin pixel<=pixel+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end
 end
 if(m_valid&&m_ready&&m_last)begin state<=DONE;end
 end else case(state)
 IDLE:if(start_valid&&start_ready)begin
 v0<=0;v1<=0;v2<=0;pixel<=0;x<=0;y<=0;frame_error<=0;error_code<=0;frame_bank<=active_bank;
 if(!table_active_valid)begin state<=DONE;frame_error<=1;error_code<=2;end else state<=FRAME;
 end
 DONE:if(done_ready)begin state<=IDLE;v0<=0;v1<=0;v2<=0;end
 default:begin state<=DONE;frame_error<=1;error_code<=4;v0<=0;v1<=0;v2<=0;end
 endcase
 end end
endmodule
