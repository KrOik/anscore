// Nine-bin unsigned HOG variant: octant-linear angle, L1 magnitude and block L1 norm.
module hog_l1_9 #(parameter BITS=8,WIDTH=32,HEIGHT=32,CELL_W=8,CELL_H=8,EPSILON=1)(
 input wire clk,rst,ce,input wire[BITS-1:0] s_gray,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output reg[15:0] m_value,
 output wire[((WIDTH/CELL_W<3)?1:$clog2(WIDTH/CELL_W-1))-1:0] m_block_x,
 output wire[((HEIGHT/CELL_H<3)?1:$clog2(HEIGHT/CELL_H-1))-1:0] m_block_y,
 output wire[5:0] m_index,output wire[1:0] m_cell,output wire[3:0] m_bin,
 output wire m_block_last,m_last,output wire done_valid,input wire done_ready,
 output reg marker_error,arithmetic_error,output wire busy
);
 localparam NX=WIDTH/CELL_W,NY=HEIGHT/CELL_H,CELLS=NX*NY,HDEPTH=CELLS<1?1:CELLS*9;
 localparam VW=NX*CELL_W,VH=NY*CELL_H,PIXELS=WIDTH*HEIGHT,D=(1<<BITS)-1;
 localparam FAW=PIXELS<2?1:$clog2(PIXELS),HAW=HDEPTH<2?1:$clog2(HDEPTH),CIW=CELLS<2?1:$clog2(CELLS);
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT),CXW=NX<2?1:$clog2(NX);
 localparam LXW=CELL_W<2?1:$clog2(CELL_W),LYW=CELL_H<2?1:$clog2(CELL_H);
 localparam BXW=NX<3?1:$clog2(NX-1),BYW=NY<3?1:$clog2(NY-1);
 localparam[63:0] MAX_HIST=64'd1*CELL_W*CELL_H*2*D*256;
 localparam HW=$clog2(MAX_HIST+1),SW=HW+3,NW=SW+17,DIVW=$clog2(NW);
 localparam CAPTURE=0,HCLEAR=1,GADDR=2,GREAD=3,GCAP=4,GRAD=5,DIVIDE=6,ANGLE=7,VMUL=8,VADDR=9,VREAD=10,VWRITE=11,BADDR=12,BREAD=13,BCAP=14,NADDR=15,NREAD=16,NCAP=17,OUTPUT=18,DONE=19;
 reg[4:0] state;
 reg[BITS-1:0] frame_mem[0:PIXELS-1],frame_q,left_pixel,right_pixel,up_pixel,down_pixel;
 reg[HW-1:0] hist_mem[0:HDEPTH-1],hist_q;
 reg[FAW-1:0] capture_addr,process_addr,frame_addr;
 reg[HAW-1:0] clear_addr,hist_addr;
 reg[XW-1:0] capture_x,px;reg[YW-1:0] capture_y,py;
 reg[CXW-1:0] cell_column;reg[CIW-1:0] cell_row_base,block_base;
 reg[LXW-1:0] local_x;reg[LYW-1:0] local_y;
 reg[1:0] neighbor;
 reg[BITS:0] magnitude;
 reg steep,negative_quadrant;
 reg[9:0] angle_ratio;
 reg[3:0] lower_bin,upper_bin;reg[7:0] fraction;
 reg[2:0] product_bit;reg[BITS+8:0] vote_product,vote_a,vote_b;reg second_vote;
 reg[SW-1:0] block_sum,block_den,divisor;
 reg[NW-1:0] dividend,quotient;
 reg[SW:0] remainder;
 reg[DIVW-1:0] division_bit;reg norm_mode;
 reg[BXW-1:0] block_x;reg[BYW-1:0] block_y;
 reg[5:0] descriptor_index;reg[1:0] descriptor_cell;reg[3:0] descriptor_bin;
 wire signed[BITS:0] gx=$signed({1'b0,right_pixel})-$signed({1'b0,left_pixel});
 wire signed[BITS:0] gy=$signed({1'b0,down_pixel})-$signed({1'b0,up_pixel});
 wire[BITS-1:0] ax=gx<0?-gx:gx,ay=gy<0?-gy:gy;
 wire[BITS:0] mag={1'b0,ax}+{1'b0,ay};
 wire[BITS-1:0] minor_gradient=ax<ay?ax:ay,major_gradient=ax<ay?ay:ax;
 wire[NW-1:0] orientation_numerator=({{(NW-BITS){1'b0}},minor_gradient}<<9)+({{(NW-BITS){1'b0}},minor_gradient}<<6);
 wire[SW:0] trial={remainder[SW-1:0],dividend[NW-1]};
 wire subtract=trial>={1'b0,divisor};
 wire[NW-1:0] quotient_next={quotient[NW-2:0],subtract};
 wire[11:0] first_quadrant=steep?12'd1152-{2'd0,angle_ratio}:{2'd0,angle_ratio};
 wire[11:0] full_angle=negative_quadrant?12'd2304-first_quadrant:first_quadrant;
 wire[11:0] angle_code=full_angle==2304?12'd0:full_angle;
 wire[BITS+8:0] magnitude_scaled={{8{1'b0}},magnitude}<<8;
 wire[BITS+8:0] product_next=vote_product+(fraction[product_bit]?(magnitude_scaled>> (8-product_bit)):0);
 wire[HW:0] hist_next={1'b0,hist_q}+(second_vote?vote_b:vote_a);
 wire[CIW:0] vote_cell={1'b0,cell_row_base}+cell_column;
 wire[CIW:0] selected_cell={1'b0,block_base}+((descriptor_cell==0)?0:(descriptor_cell==1)?1:(descriptor_cell==2)?NX:NX+1);
 wire[HAW-1:0] vote_address=(vote_cell<<3)+vote_cell+(second_vote?upper_bin:lower_bin);
 wire[HAW-1:0] block_address=(selected_cell<<3)+selected_cell+descriptor_bin;
 wire[NW-1:0] norm_numerator=({{(NW-HW){1'b0}},hist_q}<<16)-hist_q+(block_den>>1);
 assign s_ready=!rst&&ce&&state==CAPTURE;
 assign m_valid=!rst&&state==OUTPUT;
 assign m_block_x=block_x;assign m_block_y=block_y;assign m_index=descriptor_index;assign m_cell=descriptor_cell;assign m_bin=descriptor_bin;
 assign m_block_last=m_valid&&descriptor_index==35;
 assign m_last=m_block_last&&block_x==NX-2&&block_y==NY-2;
 assign done_valid=!rst&&state==DONE;
 assign busy=state!=CAPTURE||capture_addr!=0;
 always @(posedge clk)if(ce&&!rst)begin
 if(state==CAPTURE&&s_valid&&s_ready)frame_mem[capture_addr]<=s_gray;
 if(state==GREAD)frame_q<=frame_mem[frame_addr];
 if(state==HCLEAR)hist_mem[clear_addr]<=0;
 else if(state==VWRITE)hist_mem[hist_addr]<=hist_next[HW]?{HW{1'b1}}:hist_next[HW-1:0];
 if(state==VREAD||state==BREAD||state==NREAD)hist_q<=hist_mem[hist_addr];
 end
 task advance_pixel;
 begin
 if(px==VW-1&&py==VH-1)begin block_x<=0;block_y<=0;block_base<=0;descriptor_index<=0;descriptor_cell<=0;descriptor_bin<=0;block_sum<=0;state<=BADDR;end
 else begin
 if(px==VW-1)begin
 px<=0;py<=py+1'b1;process_addr<=process_addr+(WIDTH-VW+1);cell_column<=0;local_x<=0;
 if(local_y==CELL_H-1)begin local_y<=0;cell_row_base<=cell_row_base+NX;end else local_y<=local_y+1'b1;
 end else begin
 px<=px+1'b1;process_addr<=process_addr+1'b1;
 if(local_x==CELL_W-1)begin local_x<=0;cell_column<=cell_column+1'b1;end else local_x<=local_x+1'b1;
 end
 neighbor<=0;state<=GADDR;
 end
 end
 endtask
 task advance_descriptor;
 begin
 descriptor_index<=descriptor_index+1'b1;
 if(descriptor_bin==8)begin descriptor_bin<=0;descriptor_cell<=descriptor_cell+1'b1;end else descriptor_bin<=descriptor_bin+1'b1;
 end
 endtask
 initial if(BITS<8||BITS>12||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||CELL_W<1||CELL_H<1||CELL_W>32||CELL_H>32||EPSILON<1||EPSILON>65535)$fatal(1,"invalid HOG parameters");
 always @(posedge clk)begin
 if(rst)begin
 state<=CAPTURE;capture_addr<=0;capture_x<=0;capture_y<=0;process_addr<=0;px<=0;py<=0;frame_addr<=0;hist_addr<=0;clear_addr<=0;
 left_pixel<=0;right_pixel<=0;up_pixel<=0;down_pixel<=0;cell_column<=0;cell_row_base<=0;block_base<=0;local_x<=0;local_y<=0;neighbor<=0;
 magnitude<=0;steep<=0;negative_quadrant<=0;angle_ratio<=0;lower_bin<=0;upper_bin<=0;fraction<=0;product_bit<=0;vote_product<=0;vote_a<=0;vote_b<=0;second_vote<=0;
 block_sum<=0;block_den<=0;divisor<=0;dividend<=0;quotient<=0;remainder<=0;division_bit<=0;norm_mode<=0;
 block_x<=0;block_y<=0;descriptor_index<=0;descriptor_cell<=0;descriptor_bin<=0;m_value<=0;marker_error<=0;arithmetic_error<=0;
 end else if(ce)case(state)
 CAPTURE:if(s_valid&&s_ready)begin
 if(capture_addr==0)begin marker_error<=0;arithmetic_error<=0;end
 if(s_sof!=(capture_addr==0)||s_eol!=(capture_x==WIDTH-1))marker_error<=1;
 if(capture_x==WIDTH-1)begin capture_x<=0;capture_y<=capture_y+1'b1;end else capture_x<=capture_x+1'b1;
 if(capture_addr==PIXELS-1)begin
 capture_addr<=0;capture_x<=0;capture_y<=0;
 if(NX<2||NY<2)state<=DONE;
 else begin clear_addr<=0;state<=HCLEAR;end
 end else capture_addr<=capture_addr+1'b1;
 end
 HCLEAR:if(clear_addr==HDEPTH-1)begin px<=0;py<=0;process_addr<=0;cell_column<=0;cell_row_base<=0;local_x<=0;local_y<=0;neighbor<=0;state<=GADDR;end else clear_addr<=clear_addr+1'b1;
 GADDR:begin
 case(neighbor)0:frame_addr<=px==0?process_addr:process_addr-1'b1;1:frame_addr<=px==WIDTH-1?process_addr:process_addr+1'b1;2:frame_addr<=py==0?process_addr:process_addr-WIDTH;default:frame_addr<=py==HEIGHT-1?process_addr:process_addr+WIDTH;endcase
 state<=GREAD;
 end
 GREAD:state<=GCAP;
 GCAP:begin
 case(neighbor)0:left_pixel<=frame_q;1:right_pixel<=frame_q;2:up_pixel<=frame_q;default:down_pixel<=frame_q;endcase
 if(neighbor==3)state<=GRAD;else begin neighbor<=neighbor+1'b1;state<=GADDR;end
 end
 GRAD:if(mag==0)advance_pixel;
 else begin magnitude<=mag;steep<=ay>ax;negative_quadrant<=gx[BITS]^gy[BITS];dividend<=orientation_numerator;divisor<=major_gradient;quotient<=0;remainder<=0;division_bit<=0;norm_mode<=0;state<=DIVIDE;end
 DIVIDE:begin
 remainder<=subtract?trial-{1'b0,divisor}:trial;dividend<=dividend<<1;quotient<=quotient_next;
 if(division_bit==NW-1)begin
 if(norm_mode)begin m_value<=(|quotient_next[NW-1:16])?16'hffff:quotient_next[15:0];state<=OUTPUT;end
 else begin angle_ratio<=quotient_next[9:0];state<=ANGLE;end
 end else division_bit<=division_bit+1'b1;
 end
 ANGLE:begin lower_bin<=angle_code[11:8];upper_bin<=angle_code[11:8]==8?0:angle_code[11:8]+1'b1;fraction<=angle_code[7:0];vote_product<=0;product_bit<=0;state<=VMUL;end
 VMUL:begin
 vote_product<=product_next;
 if(product_bit==7)begin vote_b<=product_next;vote_a<=magnitude_scaled-product_next;second_vote<=0;state<=VADDR;end else product_bit<=product_bit+1'b1;
 end
 VADDR:begin hist_addr<=vote_address;state<=VREAD;end
 VREAD:state<=VWRITE;
 VWRITE:begin if(hist_next[HW])arithmetic_error<=1;if(second_vote)advance_pixel;else begin second_vote<=1;state<=VADDR;end end
 BADDR:begin hist_addr<=block_address;state<=BREAD;end
 BREAD:state<=BCAP;
 BCAP:begin
 block_sum<=block_sum+hist_q;
 if(descriptor_index==35)begin block_den<=block_sum+hist_q+EPSILON;descriptor_index<=0;descriptor_cell<=0;descriptor_bin<=0;state<=NADDR;end
 else begin advance_descriptor;state<=BADDR;end
 end
 NADDR:begin hist_addr<=block_address;state<=NREAD;end
 NREAD:state<=NCAP;
 NCAP:begin dividend<=norm_numerator;divisor<=block_den;quotient<=0;remainder<=0;division_bit<=0;norm_mode<=1;state<=DIVIDE;end
 OUTPUT:if(m_ready)begin
 if(descriptor_index==35)begin
 if(block_x==NX-2&&block_y==NY-2)state<=DONE;
 else begin
 if(block_x==NX-2)begin block_x<=0;block_y<=block_y+1'b1;block_base<=block_base+2;end else begin block_x<=block_x+1'b1;block_base<=block_base+1'b1;end
 descriptor_index<=0;descriptor_cell<=0;descriptor_bin<=0;block_sum<=0;state<=BADDR;
 end
 end else begin advance_descriptor;state<=NADDR;end
 end
 DONE:if(done_ready)state<=CAPTURE;
 default:state<=CAPTURE;
 endcase
 end
endmodule

