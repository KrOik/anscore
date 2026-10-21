// Elastic byte-domain BT.656 formatter. Explicit configurable line map, no PHY.
module bt656_tx #(parameter MAX_WIDTH=720,MAX_FIELD_LINES=288)(
 input wire clk,rst_n,ce,start_valid,abort,output wire start_ready,
 input wire[15:0]cfg_width,cfg_field_lines,cfg_total_lines,cfg_field1_start,
 input wire[15:0]cfg_active0_start,cfg_active1_start,
 input wire[16:0]cfg_line_bytes,
 input wire[7:0]s_data,input wire s_valid,s_sof,s_eol,s_last,s_field,output wire s_ready,
 output reg[7:0]m_data,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_last,done_valid,input wire done_ready,
 output wire frame_error,output reg[7:0]error_code,output reg[63:0]output_bytes
);
 localparam IDLE=0,EMIT=1,LOAD=2,ACTIVE=3,DONE=4;
 reg[2:0]state;
 reg[15:0]width,lines,total_lines,field1,a0,a1,row;
 reg[16:0]line_bytes,col;
 reg[7:0]payload;
 wire f=row>=field1;
 wire active_line=(!f&&{1'b0,row}>={1'b0,a0}&&{1'b0,row}<({1'b0,a0}+{1'b0,lines}))||
                  (f&&{1'b0,row}>={1'b0,a1}&&{1'b0,row}<({1'b0,a1}+{1'b0,lines}));
 wire v=!active_line;
 wire[16:0]active_end={width,1'b0}+17'd4;
 wire data_slot=col>=4&&col<active_end;
 wire h=col>=active_end;
 wire[7:0]xy={1'b1,f,v,h,v^h,f^h,f^v,f^v^h};
 assign start_ready=state==IDLE;
 assign s_ready=state==LOAD;
 assign m_valid=state==EMIT||state==ACTIVE;
 assign m_sof=row==0&&col==0;
 assign m_eol=col==line_bytes-1'b1;
 assign m_last=m_eol&&row==total_lines-1'b1;
 assign done_valid=state==DONE;
 assign frame_error=done_valid&&error_code!=0;
 always @*begin
 if(state==ACTIVE)m_data=payload;
 else if(col<4)case(col)0:m_data=255;1,2:m_data=0;default:m_data=xy;endcase
 else if(col>=active_end&&col<active_end+4)case(col-active_end)0:m_data=255;1,2:m_data=0;default:m_data=xy;endcase
 else m_data=col[0]?8'h10:8'h80;
 end
 task next_byte;
 reg[16:0]nc;
 begin
 output_bytes<=output_bytes+1'b1;
 if(col==line_bytes-1'b1)begin
 col<=0;
 if(row==total_lines-1'b1)state<=DONE;
 else begin row<=row+1'b1;state<=EMIT;end
 end else begin
 nc=col+1'b1;col<=nc;
 if(active_line&&nc>=4&&nc<active_end)state<=LOAD;
 else state<=EMIT;
 end
 end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;width<=0;lines<=0;total_lines<=0;field1<=0;a0<=0;a1<=0;row<=0;line_bytes<=0;col<=0;payload<=0;error_code<=0;output_bytes<=0;end
 else if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE)begin state<=DONE;error_code<=3;end
 else case(state)
 IDLE:if(start_valid)begin
 width<=cfg_width;lines<=cfg_field_lines;total_lines<=cfg_total_lines;field1<=cfg_field1_start;
 a0<=cfg_active0_start;a1<=cfg_active1_start;line_bytes<=cfg_line_bytes;row<=0;col<=0;output_bytes<=0;error_code<=0;
 if(MAX_WIDTH<2||MAX_WIDTH>32766||MAX_FIELD_LINES<1||MAX_FIELD_LINES>32767||
 cfg_width<2||cfg_width>MAX_WIDTH||cfg_width[0]||cfg_field_lines<1||cfg_field_lines>MAX_FIELD_LINES||
 cfg_line_bytes<({1'b0,cfg_width,1'b0}+18'd8)||cfg_line_bytes[0]||
 cfg_total_lines<2||cfg_field1_start==0||cfg_field1_start>=cfg_total_lines||
 ({1'b0,cfg_active0_start}+{1'b0,cfg_field_lines})>{1'b0,cfg_field1_start}||
 cfg_active1_start<cfg_field1_start||
 ({1'b0,cfg_active1_start}+{1'b0,cfg_field_lines})>{1'b0,cfg_total_lines})begin state<=DONE;error_code<=1;end
 else state<=EMIT;
 end
 EMIT:if(m_ready)next_byte;
 LOAD:if(s_valid)begin
 if(s_sof!=(!f&&row==a0&&col==4)||s_eol!=(col==active_end-1'b1)||
 s_last!=(f&&{1'b0,row}==({1'b0,a1}+{1'b0,lines}-1'b1)&&col==active_end-1'b1)||s_field!=f)begin state<=DONE;error_code<=2;end
 else begin payload<=s_data;state<=ACTIVE;end
 end
 ACTIVE:if(m_ready)next_byte;
 DONE:if(done_ready)state<=IDLE;
 default:state<=IDLE;
 endcase
 end
 end
endmodule
