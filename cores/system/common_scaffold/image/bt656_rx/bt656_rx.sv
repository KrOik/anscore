// Byte-domain BT.656 receiver. Strict XY protection, field-raster output.
module bt656_rx #(parameter MAX_WIDTH=720, MAX_FIELD_LINES=288)(
 input clk,rst_n,ce,start_valid,abort,
 output start_ready,input [15:0]cfg_width,cfg_field_lines,
 input [7:0]s_data,input s_valid,s_last,output s_ready,
 output reg[7:0]m_data,output reg m_valid,input m_ready,
 output reg m_sof,m_eol,m_last,m_field,m_field_sof,
 output reg done_valid,input done_ready,output frame_error,output reg[7:0]error_code
);
 localparam SCAN=0,ACTIVE=1,EAV=2;
 reg running;reg[1:0]state,prefix,eav_pos;
 reg[15:0]width,lines,line_no;reg[16:0]byte_no;
 reg expected_field;
 wire f=s_data[6],v=s_data[5],h=s_data[4];
 wire xy_good=s_data[7]&&s_data[3]==(v^h)&&s_data[2]==(f^h)&&s_data[1]==(f^v)&&s_data[0]==(f^v^h);
 assign start_ready=!running&&!done_valid;
 assign s_ready=running&&(!m_valid||m_ready);
 assign frame_error=done_valid&&(error_code!=0);
 task fail;input[7:0]code;begin running<=0;done_valid<=1;error_code<=code;m_valid<=0;end endtask
 always @(posedge clk)begin
  if(!rst_n)begin running<=0;done_valid<=0;error_code<=0;m_valid<=0;m_data<=0;m_sof<=0;m_eol<=0;m_last<=0;m_field<=0;m_field_sof<=0;state<=SCAN;prefix<=0;eav_pos<=0;width<=0;lines<=0;line_no<=0;byte_no<=0;expected_field<=0;end
  else if(ce&&abort&&running)begin running<=0;m_valid<=0;done_valid<=1;error_code<=8'h07;end
  else if(ce)begin
   if(m_valid&&m_ready)m_valid<=0;
   if(done_valid&&done_ready)done_valid<=0;
   if(start_valid&&start_ready)begin
    error_code<=0;prefix<=0;state<=SCAN;eav_pos<=0;expected_field<=0;line_no<=0;byte_no<=0;width<=cfg_width;lines<=cfg_field_lines;
    if(MAX_WIDTH<2||MAX_WIDTH>32766||MAX_FIELD_LINES<1||MAX_FIELD_LINES>32767||cfg_width<2||cfg_width>MAX_WIDTH||cfg_width[0]||cfg_field_lines==0||cfg_field_lines>MAX_FIELD_LINES)begin done_valid<=1;error_code<=1;end else running<=1;
   end
   if(s_valid&&s_ready)begin
    case(state)
    SCAN:begin
     case(prefix)
      0:if(s_data==255)prefix<=1;
      1:if(s_data==0)prefix<=2;else if(s_data!=255)prefix<=0;
      2:if(s_data==0)prefix<=3;else if(s_data==255)prefix<=1;else prefix<=0;
      3:begin
       prefix<=0;
       if(!xy_good)fail(2);
       else if(!h&&!v)begin
        if(f!=expected_field)fail(3);
        else begin state<=ACTIVE;byte_no<=0;end
       end
      end
     endcase
     if(s_last)fail(4);
    end
    ACTIVE:begin
     m_valid<=1;m_data<=s_data;m_field<=expected_field;
     m_sof<=!expected_field&&line_no==0&&byte_no==0;
     m_field_sof<=line_no==0&&byte_no==0;
     m_eol<=byte_no==({width,1'b0}-1);
     m_last<=expected_field&&line_no==lines-1&&byte_no==({width,1'b0}-1);
     if(byte_no==({width,1'b0}-1))begin state<=EAV;eav_pos<=0;end else byte_no<=byte_no+1'b1;
     if(s_last)fail(4);
    end
    EAV:begin
     if(eav_pos<3)begin
      if(s_data!=(eav_pos==0?8'hff:8'h00))fail(5);else eav_pos<=eav_pos+1'b1;
      if(s_last)fail(4);
     end else begin
      if(!xy_good)fail(2);
      else if(!h||v||f!=expected_field)fail(5);
      else if(line_no==lines-1)begin
       if(expected_field)begin running<=0;done_valid<=1;error_code<=0;end
       else begin expected_field<=1;line_no<=0;state<=SCAN;prefix<=0;if(s_last)fail(4);end
      end else begin line_no<=line_no+1'b1;state<=SCAN;prefix<=0;if(s_last)fail(4);end
     end
    end
    default:fail(6);
    endcase
   end
  end
 end
endmodule

