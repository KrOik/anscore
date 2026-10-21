// Exact L1 / L-infinity distance to in-frame zero-valued pixels.
module binary_distance_transform #(
 parameter WIDTH=8,HEIGHT=6,
 parameter DIST_W=($clog2(WIDTH+HEIGHT+1)<1?1:$clog2(WIDTH+HEIGHT+1))
)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,cfg_chessboard,output wire cfg_ready,output reg cfg_done,
 input wire s_pixel,s_valid,s_sof,s_eol,output wire s_ready,
 output reg [DIST_W-1:0] m_distance,output reg m_invalid,m_valid,m_sof,m_eol,input wire m_ready,
 output wire busy,output reg no_seed,output reg [3:0] error_code
);
 localparam CAP=0,READ=1,REDUCE=2,STORE=3,OUT_READ=4,OUT_LOAD=5,OUT_HOLD=6,FAILED=7;
 localparam [DIST_W-1:0] INF={DIST_W{1'b1}};
 reg [DIST_W-1:0] memory[0:WIDTH*HEIGHT-1],q,best;
 reg [2:0] state,tap;reg reverse,mode,has_seed;
 integer x,y,dx,dy,ax,ay;
 wire [DIST_W-1:0] candidate=tap==0?q:(q==INF?INF:q+1'b1);
 assign busy=state!=CAP||x!=0||y!=0;
 assign cfg_ready=ce&&!busy;
 assign s_ready=ce&&state==CAP&&!(cfg_valid&&!busy);
 always @* begin
 dx=0;dy=0;
 case(tap)
 1:dx=reverse?1:-1;
 2:dy=reverse?1:-1;
 3:begin dx=-1;dy=reverse?1:-1;end
 4:begin dx=1;dy=reverse?1:-1;end
 endcase
 ax=x+dx;ay=y+dy;
 end
 initial if(WIDTH<1||HEIGHT<1||DIST_W<$clog2(WIDTH+HEIGHT+1)) $fatal(1,"invalid distance geometry/width");
 always @(posedge clk) begin
 if(!rst_n) begin
 state<=CAP;tap<=0;reverse<=0;mode<=0;has_seed<=0;x<=0;y<=0;q<=0;best<=INF;
 m_distance<=0;m_invalid<=0;m_valid<=0;m_sof<=0;m_eol<=0;no_seed<=0;error_code<=0;cfg_done<=0;
 end else if(ce) begin
 cfg_done<=0;
 if(cfg_valid&&cfg_ready) begin mode<=cfg_chessboard;cfg_done<=1;end
 case(state)
 CAP:if(s_valid&&s_ready) begin
 if(s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1)) begin error_code<=1;state<=FAILED;end
 else begin
 memory[y*WIDTH+x]<=s_pixel?INF:{DIST_W{1'b0}};
 if(!s_pixel) has_seed<=1;
 if(x==0&&y==0) no_seed<=0;
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin y<=0;reverse<=0;tap<=0;best<=INF;state<=READ;no_seed<=!has_seed&&s_pixel;end
 else y<=y+1;
 end else x<=x+1;
 end end
 READ:begin
 if(ax<0||ax>=WIDTH||ay<0||ay>=HEIGHT) q<=INF;else q<=memory[ay*WIDTH+ax];
 state<=REDUCE;
 end
 REDUCE:begin
 if(candidate<best) best<=candidate;
 if(tap==(mode?4:2)) state<=STORE;else begin tap<=tap+1'b1;state<=READ;end
 end
 STORE:begin
 memory[y*WIDTH+x]<=best;tap<=0;best<=INF;
 if(!reverse) begin
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin reverse<=1;x<=WIDTH-1;y<=HEIGHT-1;state<=READ;end
 else begin y<=y+1;state<=READ;end
 end else begin x<=x+1;state<=READ;end
 end else begin
 if(x==0) begin
 if(y==0) begin x<=0;y<=0;state<=OUT_READ;end
 else begin x<=WIDTH-1;y<=y-1;state<=READ;end
 end else begin x<=x-1;state<=READ;end
 end end
 OUT_READ:begin q<=memory[y*WIDTH+x];state<=OUT_LOAD;end
 OUT_LOAD:begin m_distance<=q;m_invalid<=q==INF;m_sof<=x==0&&y==0;m_eol<=x==WIDTH-1;m_valid<=1;state<=OUT_HOLD;end
 OUT_HOLD:if(m_ready) begin
 m_valid<=0;
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin y<=0;has_seed<=0;state<=CAP;end else begin y<=y+1;state<=OUT_READ;end
 end else begin x<=x+1;state<=OUT_READ;end
 end
 FAILED:begin end
 endcase
 end end
endmodule
