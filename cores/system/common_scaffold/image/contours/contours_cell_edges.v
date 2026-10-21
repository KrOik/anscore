// Exact cell-edge contours. Foreground4/background8; foreground on right.
module contours_cell_edges #(parameter WIDTH=32,HEIGHT=32)(
 input wire clk,rst,ce,s_pixel,s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,
 output reg[((WIDTH<1)?1:$clog2(WIDTH+1))-1:0] m_x,
 output reg[((HEIGHT<1)?1:$clog2(HEIGHT+1))-1:0] m_y,
 output reg[1:0] m_dir,output reg m_contour_start,m_contour_end,m_hole,
 output reg signed[31:0] m_area2,
 output reg[$clog2(WIDTH*HEIGHT+1)-1:0] m_contour_index,
 output reg[$clog2(4*WIDTH*HEIGHT+1)-1:0] m_edge_index,
 output wire done_valid,input wire done_ready,output reg[1:0] error_code,
 output reg[$clog2(WIDTH*HEIGHT+1)-1:0] foreground_count,contour_count,
 output reg[$clog2(4*WIDTH*HEIGHT+1)-1:0] edge_count,output wire busy
);
 localparam N=WIDTH*HEIGHT,V=(WIDTH+1)*(HEIGHT+1),PA=N<2?1:$clog2(N),VA=V<2?1:$clog2(V);
 localparam XW=$clog2(WIDTH+1),YW=$clog2(HEIGHT+1),CW=$clog2(N+1),EW=$clog2(4*N+1);
 localparam CAP=0,EVAL=1,BA=2,BR=3,BC=4,BW=5,SA=6,SR=7,SC=8,TA=9,TR=10,TC=11,WRITE=12,OUT=13,DONE=14;
 reg[3:0] state;
 reg pixels[0:N-1],pixel_q;reg[7:0] edges[0:V-1],edge_q;
 reg[PA-1:0] capture_addr,pixel_addr;reg[VA-1:0] vertex_addr,edge_addr,scan_addr;
 reg[XW-1:0] cx,vx,x,start_x,next_x;reg[YW-1:0] cy,vy,y,start_y,next_y;
 reg[1:0] quadrant,chosen,last_dir;reg[3:0] samples,remaining;
 reg[3:0] start_mask;reg[1:0] start_dir;reg closes;reg close_found;integer cd,ck;
 reg first;reg signed[31:0] area,updated_area;reg[EW-1:0] local_edges;
 integer px,py,k,d;reg pick_found;reg[1:0] pick;
 wire sample_valid=px>=0&&px<WIDTH&&py>=0&&py<HEIGHT;
 wire[3:0] built={samples[1]&&!samples[0],samples[0]&&!samples[2],samples[2]&&!samples[3],samples[3]&&!samples[1]};
 // Explicit constant shift/add addresses prevent constant-stride DSP inference.
 function[VA-1:0] vertex_row;
 input[YW-1:0] row;integer b;
 begin vertex_row=0;for(b=0;b<13;b=b+1)if(((WIDTH+1)>>b)&1)vertex_row=vertex_row+({{VA{1'b0}},row}<<b);end
 endfunction
 function[PA-1:0] pixel_row;
 input[YW-1:0] row;integer b;
 begin pixel_row=0;for(b=0;b<13;b=b+1)if((WIDTH>>b)&1)pixel_row=pixel_row+({{PA{1'b0}},row}<<b);end
 endfunction
 assign s_ready=!rst&&ce&&state==CAP;assign m_valid=!rst&&state==OUT;
 assign done_valid=!rst&&state==DONE;assign busy=state!=CAP||capture_addr!=0;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||N>4096)$fatal(1,"invalid contours geometry");
 always @* begin
 px=$signed({1'b0,vx});py=$signed({1'b0,vy});
 if(quadrant==0||quadrant==2)px=px-1;
 if(quadrant==0||quadrant==1)py=py-1;
 pick=0;pick_found=0;
 for(k=0;k<4;k=k+1)begin
 if(first)d=k;else case(k)0:d=(last_dir+1)&3;1:d=last_dir;2:d=(last_dir+3)&3;default:d=(last_dir+2)&3;endcase
 if(!pick_found&&(first?edge_q[d]:edge_q[d+4]))begin pick=d;pick_found=1;end
 end
 next_x=x;next_y=y;updated_area=area;
 case(chosen)
 0:begin next_x=x+1'b1;updated_area=area-$signed({1'b0,y});end
 1:begin next_y=y+1'b1;updated_area=area+$signed({1'b0,x});end
 2:begin next_x=x-1'b1;updated_area=area+$signed({1'b0,y});end
 3:begin next_y=y-1'b1;updated_area=area-$signed({1'b0,x});end
 endcase
 closes=0;close_found=0;
 for(ck=0;ck<4;ck=ck+1)begin
 case(ck)0:cd=(chosen+1)&3;1:cd=chosen;2:cd=(chosen+3)&3;default:cd=(chosen+2)&3;endcase
 if(!close_found&&start_mask[cd])begin
 close_found=1;closes=next_x==start_x&&next_y==start_y&&cd==start_dir;
 end
 end
 end
 always @(posedge clk)if(ce&&!rst)begin
 if(state==CAP&&s_valid)pixels[capture_addr]<=s_pixel;
 if(state==BR)pixel_q<=pixels[pixel_addr];
 if(state==BW)edges[vertex_addr]<={built,built};
 if(state==SR||state==TR)edge_q<=edges[edge_addr];
 if(state==WRITE)edges[edge_addr]<={edge_q[7:4],remaining};
 end
 always @(posedge clk)begin
 if(rst)begin
 state<=CAP;capture_addr<=0;pixel_addr<=0;vertex_addr<=0;edge_addr<=0;scan_addr<=0;
 cx<=0;cy<=0;vx<=0;vy<=0;x<=0;y<=0;start_x<=0;start_y<=0;quadrant<=0;
 start_mask<=0;start_dir<=0;samples<=0;chosen<=0;last_dir<=0;remaining<=0;first<=0;area<=0;local_edges<=0;
 m_x<=0;m_y<=0;m_dir<=0;m_contour_start<=0;m_contour_end<=0;m_hole<=0;m_area2<=0;m_contour_index<=0;m_edge_index<=0;
 error_code<=0;foreground_count<=0;contour_count<=0;edge_count<=0;
 end else if(ce)case(state)
 CAP:if(s_valid)begin
 if(capture_addr==0)begin error_code<={1'b0,(!s_sof||s_eol!=(WIDTH==1))};foreground_count<=s_pixel;contour_count<=0;edge_count<=0;end
 else begin if(s_sof||s_eol!=(cx==WIDTH-1))error_code[0]<=1;if(s_pixel)foreground_count<=foreground_count+1'b1;end
 if(capture_addr==N-1)state<=EVAL;
 else begin capture_addr<=capture_addr+1'b1;if(cx==WIDTH-1)begin cx<=0;cy<=cy+1'b1;end else cx<=cx+1'b1;end
 end
 EVAL:if(error_code!=0)state<=DONE;else begin vertex_addr<=0;vx<=0;vy<=0;quadrant<=0;samples<=0;state<=BA;end
 BA:if(sample_valid)begin pixel_addr<=pixel_row(py)+px;state<=BR;end else begin samples[quadrant]<=0;if(quadrant==3)state<=BW;else quadrant<=quadrant+1'b1;end
 BR:state<=BC;
 BC:begin samples[quadrant]<=pixel_q;if(quadrant==3)state<=BW;else begin quadrant<=quadrant+1'b1;state<=BA;end end
 BW:if(vertex_addr==V-1)begin scan_addr<=0;x<=0;y<=0;state<=SA;end else begin
 vertex_addr<=vertex_addr+1'b1;if(vx==WIDTH)begin vx<=0;vy<=vy+1'b1;end else vx<=vx+1'b1;quadrant<=0;state<=BA;end
 SA:begin edge_addr<=scan_addr;state<=SR;end
 SR:state<=SC;
 SC:if(edge_q[3:0]!=0)begin first<=1;start_mask<=edge_q[7:4];start_x<=x;start_y<=y;area<=0;local_edges<=0;state<=TC;end
 else if(scan_addr==V-1)state<=DONE;
 else begin scan_addr<=scan_addr+1'b1;if(x==WIDTH)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=SA;end
 TA:begin edge_addr<=vertex_row(y)+x;state<=TR;end
 TR:state<=TC;
 TC:if(!pick_found||!edge_q[pick]||edge_count==4*N||contour_count==N)begin error_code[1]<=1;state<=DONE;end
 else begin chosen<=pick;if(first)start_dir<=pick;remaining<=edge_q[3:0]&~(4'b1<<pick);state<=WRITE;end
 WRITE:begin
 m_x<=x;m_y<=y;m_dir<=chosen;m_contour_start<=first;
 m_contour_end<=closes;
 m_area2<=(closes)?updated_area:0;
 m_hole<=(closes)&&updated_area<0;
 m_contour_index<=contour_count;m_edge_index<=local_edges;state<=OUT;
 end
 OUT:if(m_ready)begin
 edge_count<=edge_count+1'b1;local_edges<=local_edges+1'b1;area<=updated_area;last_dir<=chosen;first<=0;
 if(m_contour_end)begin contour_count<=contour_count+1'b1;scan_addr<=0;x<=0;y<=0;state<=SA;end
 else begin x<=next_x;y<=next_y;state<=TA;end
 end
 DONE:if(done_ready)begin capture_addr<=0;cx<=0;cy<=0;state<=CAP;end
 endcase end
endmodule
