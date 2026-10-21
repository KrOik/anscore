module zhang_suen_thinning #(parameter WIDTH=16,HEIGHT=16,MAX_ITERATIONS=64)(
 input wire clk,rst_n,ce,
 input wire s_pixel,s_valid,s_sof,s_eol,output wire s_ready,
 output reg m_pixel,m_valid,m_sof,m_eol,input wire m_ready,
 output wire busy,output reg done,converged,output reg [15:0] iterations,output reg [3:0] error_code
);
 localparam [63:0] TOTAL=64'd1*WIDTH*HEIGHT;
 localparam N=(TOTAL>=1&&TOTAL<=65536)?TOTAL:1;
 localparam CAP=0,READ=1,SAVE=2,CALCULATE=3,STORE=4,OUT_READ=5,OUT_LOAD=6,OUT_HOLD=7;
 reg [2:0] state;reg memory[0:2*N-1],q,source_bank,phase,changed,keep,remove;
 reg [8:0] p;reg [3:0] tap;
 integer x,y,dx,dy,ax,ay,k,bcount,transitions;
 reg deletion;
 assign s_ready=ce&&state==CAP;
 assign busy=state!=CAP||x!=0||y!=0;
 always @* begin
 dx=0;dy=0;
 case(tap)
 1:dy=-1;2:begin dx=1;dy=-1;end 3:dx=1;4:begin dx=1;dy=1;end
 5:dy=1;6:begin dx=-1;dy=1;end 7:dx=-1;8:begin dx=-1;dy=-1;end
 endcase
 ax=x+dx;ay=y+dy;
 bcount=0;transitions=0;
 for(k=1;k<=8;k=k+1) begin
 bcount=bcount+p[k];
 if(!p[k]&&p[k==8?1:k+1]) transitions=transitions+1;
 end
 deletion=p[0]&&bcount>=2&&bcount<=6&&transitions==1;
 if(!phase) deletion=deletion&&!(p[1]&&p[3]&&p[5])&&!(p[3]&&p[5]&&p[7]);
 else deletion=deletion&&!(p[1]&&p[3]&&p[7])&&!(p[1]&&p[5]&&p[7]);
 end
 initial if(WIDTH<1||HEIGHT<1||TOTAL>65536||MAX_ITERATIONS<1||MAX_ITERATIONS>65535) $fatal(1,"invalid thinning parameters");
 always @(posedge clk) begin
 if(!rst_n) begin
 state<=CAP;x<=0;y<=0;tap<=0;p<=0;q<=0;source_bank<=0;phase<=0;changed<=0;keep<=0;remove<=0;
 m_pixel<=0;m_valid<=0;m_sof<=0;m_eol<=0;done<=0;converged<=0;iterations<=0;error_code<=0;
 end else if(ce) begin
 done<=0;
 case(state)
 CAP:if(s_valid&&s_ready) begin
 if(x==0&&y==0) begin error_code<=0;converged<=0;iterations<=0;end
 if(s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1)) begin error_code<=1;x<=0;y<=0;done<=1;converged<=0;iterations<=0;end
 else begin
 memory[y*WIDTH+x]<=s_pixel;
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin y<=0;tap<=0;source_bank<=0;phase<=0;changed<=0;state<=READ;end else y<=y+1;
 end else x<=x+1;
 end end
 READ:begin
 if(ax<0||ax>=WIDTH||ay<0||ay>=HEIGHT) q<=0;else q<=memory[source_bank*N+ay*WIDTH+ax];
 state<=SAVE;end
 SAVE:begin p[tap]<=q;
 if(tap==8) state<=CALCULATE;else begin tap<=tap+1'b1;state<=READ;end
 end
 CALCULATE:begin remove<=deletion;keep<=p[0]&&!deletion;state<=STORE;end
 STORE:begin
 memory[(!source_bank)*N+y*WIDTH+x]<=keep;
 if(remove) changed<=1;
 tap<=0;
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin
 y<=0;source_bank<=!source_bank;
 if(!phase) begin phase<=1;state<=READ;end
 else begin
 iterations<=iterations+1'b1;
 if(!(changed||remove)) begin converged<=1;state<=OUT_READ;end
 else if(iterations+1>=MAX_ITERATIONS) begin converged<=0;error_code<=2;state<=OUT_READ;end
 else begin phase<=0;changed<=0;state<=READ;end
 end
 end else begin y<=y+1;state<=READ;end
 end else begin x<=x+1;state<=READ;end
 end
 OUT_READ:begin q<=memory[source_bank*N+y*WIDTH+x];state<=OUT_LOAD;end
 OUT_LOAD:begin m_pixel<=q;m_valid<=1;m_sof<=x==0&&y==0;m_eol<=x==WIDTH-1;state<=OUT_HOLD;end
 OUT_HOLD:if(m_ready) begin
 m_valid<=0;
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin y<=0;state<=CAP;done<=1;end else begin y<=y+1;state<=OUT_READ;end
 end else begin x<=x+1;state<=OUT_READ;end
 end
 endcase
 end end
endmodule
