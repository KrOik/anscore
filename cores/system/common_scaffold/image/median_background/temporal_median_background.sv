// Previous completed frames only; current sample is written AFTER median use.
module temporal_median_background #(parameter WIDTH=8,HEIGHT=6,BITS=8,WINDOW=3)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,input wire [BITS-1:0] cfg_threshold,output reg cfg_done,
 input wire [BITS-1:0] s_pixel,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg [BITS-1:0] m_background,output reg m_foreground,m_warmup,m_valid,m_sof,m_eol,input wire m_ready,
 output wire busy,output reg done,output reg [3:0] error_code
);
 localparam CAP=0,READ=1,SAVE=2,COMPUTE=3,HOLD=4;
 reg [2:0] state;
 reg [BITS-1:0] history[0:WINDOW*WIDTH*HEIGHT-1],samples[0:WINDOW-1],q,pixel,threshold;
 reg [BITS-1:0] sorted[0:WINDOW-1],swap;
 integer x,y,slot,read_slot,completed,i,j;
 wire valid_history=completed==WINDOW;
 wire [BITS-1:0] median=sorted[WINDOW/2];
 wire [BITS:0] difference=pixel>=median?{1'b0,pixel}-{1'b0,median}:{1'b0,median}-{1'b0,pixel};
 assign busy=state!=CAP||x!=0||y!=0;
 assign cfg_ready=ce&&!busy;
 assign s_ready=ce&&state==CAP&&!(cfg_valid&&!busy);
 always @* begin
 for(i=0;i<WINDOW;i=i+1) sorted[i]=samples[i];
 swap=0;
 for(i=0;i<WINDOW;i=i+1) for(j=0;j<WINDOW-1;j=j+1)
 if(sorted[j]>sorted[j+1]) begin swap=sorted[j];sorted[j]=sorted[j+1];sorted[j+1]=swap;end
 end
 initial if(WIDTH<1||HEIGHT<1||BITS<8||BITS>16||(WINDOW!=3&&WINDOW!=5)) $fatal(1,"invalid median background parameters");
 always @(posedge clk) begin
 if(!rst_n) begin
 state<=CAP;x<=0;y<=0;slot<=0;read_slot<=0;completed<=0;threshold<=0;q<=0;pixel<=0;
 cfg_done<=0;m_background<=0;m_foreground<=0;m_warmup<=1;m_valid<=0;m_sof<=0;m_eol<=0;done<=0;error_code<=0;
 end else if(ce) begin
 cfg_done<=0;done<=0;
 if(cfg_valid&&cfg_ready) begin threshold<=cfg_threshold;cfg_done<=1;end
 case(state)
 CAP:if(s_valid&&s_ready) begin
 if(x==0&&y==0) error_code<=0;
 if(s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1)) begin
 // Partial ring-slot writes are invalidated by a complete warmup restart.
 x<=0;y<=0;slot<=0;completed<=0;error_code<=1;done<=1;m_valid<=0;state<=CAP;
 end else begin pixel<=s_pixel;read_slot<=0;state<=READ;end
 end
 READ:begin q<=history[read_slot*WIDTH*HEIGHT+y*WIDTH+x];state<=SAVE;end
 SAVE:begin samples[read_slot]<=q;
 if(read_slot==WINDOW-1) state<=COMPUTE;else begin read_slot<=read_slot+1;state<=READ;end
 end
 COMPUTE:begin
 m_background<=valid_history?median:{BITS{1'b0}};
 m_foreground<=valid_history&&(difference>{1'b0,threshold});m_warmup<=!valid_history;
 m_sof<=x==0&&y==0;m_eol<=x==WIDTH-1;m_valid<=1;
 history[slot*WIDTH*HEIGHT+y*WIDTH+x]<=pixel;
 state<=HOLD;
 end
 HOLD:if(m_ready) begin
 m_valid<=0;
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin
 y<=0;slot<=slot==WINDOW-1?0:slot+1;if(completed<WINDOW) completed<=completed+1;
 done<=1;state<=CAP;
 end else begin y<=y+1;state<=CAP;end
 end else begin x<=x+1;state<=CAP;end
 end
 endcase
 end end
endmodule
