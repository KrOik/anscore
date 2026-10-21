// Exact boundary-background BFS, mark-on-enqueue; queue capacity is full frame.
module binary_hole_fill #(parameter WIDTH=16,HEIGHT=16,CONNECT8=0)(
 input wire clk,rst_n,ce,
 input wire s_pixel,s_valid,s_sof,s_eol,output wire s_ready,
 output reg m_pixel,m_hole,m_valid,m_sof,m_eol,input wire m_ready,
 output wire busy,output reg done,output reg [31:0] filled_count,output reg [3:0] error_code
);
 localparam [63:0] TOTAL=64'd1*WIDTH*HEIGHT;
 localparam N=(TOTAL>=1&&TOTAL<=65536)?TOTAL:1;
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT),CW=$clog2(N+1);
 localparam CAP=0,QUEUE_CHECK=1,QUEUE_READ=2,QUEUE_DECODE=3,NEIGH_READ=4,NEIGH_CHECK=5,OUT_READ=6,OUT_LOAD=7,OUT_HOLD=8;
 reg [3:0] state;reg image[0:N-1],visited[0:N-1],image_q,visited_q;
 reg [XW+YW-1:0] queue[0:N-1],queue_q;
 reg [CW-1:0] head,tail;
 reg [2:0] neighbor;
 integer x,y,cx,cy,dx,dy,ax,ay;
 wire boundary=x==0||y==0||x==WIDTH-1||y==HEIGHT-1;
 wire in_bounds=ax>=0&&ax<WIDTH&&ay>=0&&ay<HEIGHT;
 wire last_neighbor=neighbor==(CONNECT8?7:6);
 assign s_ready=ce&&state==CAP;
 assign busy=state!=CAP||x!=0||y!=0;
 always @* begin
 dx=0;dy=0;
 case(neighbor)
 0:dy=-1;1:begin dx=1;dy=-1;end 2:dx=1;3:begin dx=1;dy=1;end
 4:dy=1;5:begin dx=-1;dy=1;end 6:dx=-1;7:begin dx=-1;dy=-1;end
 endcase
 ax=cx+dx;ay=cy+dy;
 end
 initial if(WIDTH<1||WIDTH>65535||HEIGHT<1||HEIGHT>65535||TOTAL>65536||(CONNECT8!=0&&CONNECT8!=1)) $fatal(1,"invalid hole-fill parameters");
 always @(posedge clk) begin
 if(!rst_n) begin
 state<=CAP;x<=0;y<=0;cx<=0;cy<=0;head<=0;tail<=0;neighbor<=0;queue_q<=0;image_q<=0;visited_q<=0;
 m_pixel<=0;m_hole<=0;m_valid<=0;m_sof<=0;m_eol<=0;done<=0;filled_count<=0;error_code<=0;
 end else if(ce) begin
 done<=0;
 case(state)
 CAP:if(s_valid&&s_ready) begin
 if(x==0&&y==0) begin error_code<=0;filled_count<=0;end
 if(s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1)) begin
 error_code<=1;x<=0;y<=0;head<=0;tail<=0;state<=CAP;done<=1;
 end else begin
 image[y*WIDTH+x]<=s_pixel;visited[y*WIDTH+x]<=!s_pixel&&boundary;
 if(!s_pixel&&boundary) begin queue[tail]<={y[YW-1:0],x[XW-1:0]};tail<=tail+1'b1;end
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin y<=0;head<=0;state<=QUEUE_CHECK;end else y<=y+1;
 end else x<=x+1;
 end end
 QUEUE_CHECK:if(head<tail) state<=QUEUE_READ;else begin x<=0;y<=0;state<=OUT_READ;end
 QUEUE_READ:begin queue_q<=queue[head];head<=head+1'b1;state<=QUEUE_DECODE;end
 QUEUE_DECODE:begin cx<=queue_q[XW-1:0];cy<=queue_q[XW+YW-1:XW];neighbor<=0;state<=NEIGH_READ;end
 NEIGH_READ:begin
 if(in_bounds) begin image_q<=image[ay*WIDTH+ax];visited_q<=visited[ay*WIDTH+ax];end
 else begin image_q<=1;visited_q<=1;end
 state<=NEIGH_CHECK;
 end
 NEIGH_CHECK:begin
 if(in_bounds&&!image_q&&!visited_q) begin
 if(tail>=N) begin error_code<=2;done<=1;x<=0;y<=0;head<=0;tail<=0;state<=CAP;end
 else begin
 visited[ay*WIDTH+ax]<=1;queue[tail]<={ay[YW-1:0],ax[XW-1:0]};tail<=tail+1'b1;
 if(last_neighbor) state<=QUEUE_CHECK;else begin neighbor<=neighbor+(CONNECT8?1:2);state<=NEIGH_READ;end
 end
 end else if(last_neighbor) state<=QUEUE_CHECK;else begin neighbor<=neighbor+(CONNECT8?1:2);state<=NEIGH_READ;end
 end
 OUT_READ:begin image_q<=image[y*WIDTH+x];visited_q<=visited[y*WIDTH+x];state<=OUT_LOAD;end
 OUT_LOAD:begin
 m_pixel<=image_q||!visited_q;m_hole<=!image_q&&!visited_q;
 if(!image_q&&!visited_q) filled_count<=filled_count+1'b1;
 m_valid<=1;m_sof<=x==0&&y==0;m_eol<=x==WIDTH-1;state<=OUT_HOLD;
 end
 OUT_HOLD:if(m_ready) begin
 m_valid<=0;
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin y<=0;head<=0;tail<=0;state<=CAP;done<=1;end
 else begin y<=y+1;state<=OUT_READ;end
 end else begin x<=x+1;state<=OUT_READ;end
 end
 endcase
 end end
endmodule
