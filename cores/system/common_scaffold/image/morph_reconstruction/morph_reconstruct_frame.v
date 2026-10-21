// Simultaneous geodesic reconstruction; two synchronous state banks, immutable mask.
module morph_reconstruct_frame #(parameter BITS=8,WIDTH=32,HEIGHT=32)(
 input wire clk,rst,ce,
 input wire cfg_erosion,cfg_connect8,input wire[15:0] cfg_max_iterations,
 input wire[BITS-1:0] s_marker,s_mask,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output reg[BITS-1:0] m_pixel,
 output wire[((WIDTH<2)?1:$clog2(WIDTH))-1:0] m_x,
 output wire[((HEIGHT<2)?1:$clog2(HEIGHT))-1:0] m_y,
 output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,
 output reg converged,limit_reached,marker_error,constraint_error,config_error,
 output reg[15:0] iterations_done,output wire busy
);
 localparam PIXELS=WIDTH*HEIGHT,AW=PIXELS<2?1:$clog2(PIXELS);
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT);
 localparam CAPTURE=0,EVALUATE=1,PADDR=2,PREAD=3,PCAP=4,NADDR=5,NREAD=6,NCAP=7,
 WRITE=8,ITER_DONE=9,OADDR=10,OREAD=11,OCAP=12,OUTPUT=13,DONE=14;
 reg[3:0] state;
 reg[BITS-1:0] state_a[0:PIXELS-1],state_b[0:PIXELS-1],mask_mem[0:PIXELS-1];
 reg[BITS-1:0] state_q,mask_q,old_pixel,mask_pixel,extremum;
 reg[AW-1:0] capture_addr,process_addr,read_addr,output_addr;
 reg[XW-1:0] capture_x,x;reg[YW-1:0] capture_y,y;
 reg active_bank,erosion,connect8,changed;
 reg[15:0] max_iterations;
 reg[2:0] neighbor_index;
 integer neighbor_x,neighbor_y;
 wire input_erosion=capture_addr==0?cfg_erosion:erosion;
 wire constraint_bad=input_erosion?s_marker<s_mask:s_marker>s_mask;
 wire neighbor_valid=neighbor_x>=0&&neighbor_x<WIDTH&&neighbor_y>=0&&neighbor_y<HEIGHT&&(connect8||neighbor_index<4);
 wire[BITS-1:0] neighbor_extreme=erosion?(state_q<extremum?state_q:extremum):(state_q>extremum?state_q:extremum);
 wire[BITS-1:0] new_pixel=erosion?(extremum<mask_pixel?mask_pixel:extremum):(extremum>mask_pixel?mask_pixel:extremum);
 assign s_ready=!rst&&ce&&state==CAPTURE;
 assign m_valid=!rst&&state==OUTPUT;
 assign m_x=x;assign m_y=y;
 assign m_sof=m_valid&&x==0&&y==0;assign m_eol=m_valid&&x==WIDTH-1;assign m_last=m_eol&&y==HEIGHT-1;
 assign done_valid=!rst&&state==DONE;
 assign busy=state!=CAPTURE||capture_addr!=0;
 always @* begin
 neighbor_x=$signed({1'b0,x});neighbor_y=$signed({1'b0,y});
 case(neighbor_index)
 0:neighbor_y=neighbor_y-1;
 1:neighbor_x=neighbor_x-1;
 2:neighbor_x=neighbor_x+1;
 3:neighbor_y=neighbor_y+1;
 4:begin neighbor_x=neighbor_x-1;neighbor_y=neighbor_y-1;end
 5:begin neighbor_x=neighbor_x+1;neighbor_y=neighbor_y-1;end
 6:begin neighbor_x=neighbor_x-1;neighbor_y=neighbor_y+1;end
 7:begin neighbor_x=neighbor_x+1;neighbor_y=neighbor_y+1;end
 endcase
 end
 always @(posedge clk)if(ce&&!rst)begin
 if(state==CAPTURE&&s_valid&&s_ready)begin state_a[capture_addr]<=s_marker;mask_mem[capture_addr]<=s_mask;end
 if(state==PREAD||state==NREAD||state==OREAD)begin
 if(active_bank)state_q<=state_b[read_addr];else state_q<=state_a[read_addr];
 end
 if(state==PREAD)mask_q<=mask_mem[process_addr];
 if(state==WRITE)begin if(active_bank)state_a[process_addr]<=new_pixel;else state_b[process_addr]<=new_pixel;end
 end
 task next_neighbor;
 begin if(neighbor_index==7)state<=WRITE;else begin neighbor_index<=neighbor_index+1'b1;state<=NADDR;end end
 endtask
 initial if(BITS<8||BITS>12||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096)$fatal(1,"invalid reconstruction parameters");
 always @(posedge clk)begin
 if(rst)begin
 state<=CAPTURE;capture_addr<=0;process_addr<=0;read_addr<=0;output_addr<=0;capture_x<=0;capture_y<=0;x<=0;y<=0;
 active_bank<=0;erosion<=0;connect8<=0;changed<=0;max_iterations<=0;neighbor_index<=0;old_pixel<=0;mask_pixel<=0;extremum<=0;m_pixel<=0;
 converged<=0;limit_reached<=0;marker_error<=0;constraint_error<=0;config_error<=0;iterations_done<=0;
 end else if(ce)case(state)
 CAPTURE:if(s_valid&&s_ready)begin
 if(capture_addr==0)begin
 erosion<=cfg_erosion;connect8<=cfg_connect8;max_iterations<=cfg_max_iterations;
 config_error<=cfg_max_iterations==0;converged<=0;limit_reached<=0;marker_error<=0;constraint_error<=0;iterations_done<=0;
 end
 if(constraint_bad)constraint_error<=1;
 if(s_sof!=(capture_addr==0)||s_eol!=(capture_x==WIDTH-1))marker_error<=1;
 if(capture_x==WIDTH-1)begin capture_x<=0;capture_y<=capture_y+1'b1;end else capture_x<=capture_x+1'b1;
 if(capture_addr==PIXELS-1)begin capture_addr<=0;capture_x<=0;capture_y<=0;state<=EVALUATE;end
 else capture_addr<=capture_addr+1'b1;
 end
 EVALUATE:begin
 active_bank<=0;x<=0;y<=0;process_addr<=0;output_addr<=0;changed<=0;
 if(config_error||constraint_error)state<=OADDR;else state<=PADDR;
 end
 PADDR:begin read_addr<=process_addr;state<=PREAD;end
 PREAD:state<=PCAP;
 PCAP:begin old_pixel<=state_q;extremum<=state_q;mask_pixel<=mask_q;neighbor_index<=0;state<=NADDR;end
 NADDR:if(neighbor_valid)begin read_addr<=neighbor_y*WIDTH+neighbor_x;state<=NREAD;end else next_neighbor;
 NREAD:state<=NCAP;
 NCAP:begin extremum<=neighbor_extreme;next_neighbor;end
 WRITE:begin
 if(new_pixel!=old_pixel)changed<=1;
 if(process_addr==PIXELS-1)state<=ITER_DONE;
 else begin process_addr<=process_addr+1'b1;if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=PADDR;end
 end
 ITER_DONE:begin
 active_bank<=!active_bank;iterations_done<=iterations_done+1'b1;x<=0;y<=0;process_addr<=0;output_addr<=0;
 if(!changed)begin converged<=1;state<=OADDR;end
 else if(iterations_done==max_iterations-1'b1)begin limit_reached<=1;state<=OADDR;end
 else begin changed<=0;state<=PADDR;end
 end
 OADDR:begin read_addr<=output_addr;state<=OREAD;end
 OREAD:state<=OCAP;
 OCAP:begin m_pixel<=state_q;state<=OUTPUT;end
 OUTPUT:if(m_ready)begin
 if(output_addr==PIXELS-1)state<=DONE;
 else begin output_addr<=output_addr+1'b1;if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=OADDR;end
 end
 DONE:if(done_ready)state<=CAPTURE;
 default:state<=CAPTURE;
 endcase
 end
endmodule
