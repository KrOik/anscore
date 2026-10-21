// Bounded frame-buffer reconstruction. All RAM reads are synchronous.
module chroma_420_to_444 #(parameter BITS=8, WIDTH=8, HEIGHT=6)(
 input wire clk,rst_n,ce,
 input wire cfg_valid, output wire cfg_ready,
 input wire [1:0] cfg_mode,cfg_h_siting,cfg_v_siting,
 output reg cfg_done,cfg_error,
 input wire [2*BITS:0] s_tdata, input wire s_tvalid,s_tuser,s_tlast,
 output wire s_tready,
 output reg [3*BITS-1:0] m_tdata,output reg m_tvalid,m_tuser,m_tlast,
 input wire m_tready,output wire busy, output reg marker_error
);
 localparam CW=(WIDTH+1)/2, CH=(HEIGHT+1)/2;
 localparam CAP=0, ADDRESS=1, READ_Y=2, READ_A=3, READ_B=4, READ_C=5, READ_D=6, EMIT=7;
 reg [2*BITS-1:0] ymem[0:CW*HEIGHT-1];
 reg [2*BITS-1:0] cmem[0:CW*CH-1];
 reg [3:0] state;
 integer ix,iy,ox,oy,xa,xb,ya,yb,fx,fy;
 reg expect_chroma,mode,hs,vs;
 reg [2*BITS-1:0] yq,cq,a,b,c,d;
 reg [BITS-1:0] luma;
 integer nx,ny,basex,basey,fracx,fracy;
 wire chroma_line = iy[0] || iy==HEIGHT-1;
 wire final_word = ix==CW-1 && (!chroma_line || expect_chroma);
 assign busy = state!=CAP || ix!=0 || iy!=0 || expect_chroma;
 assign cfg_ready = ce && !busy;
 assign s_tready = ce && state==CAP && !(cfg_valid && !busy);
 function [BITS-1:0] interp;
 input [BITS-1:0] aa,bb,cc,dd;
 integer sum;
 begin
 sum=aa*(4-fx)*(4-fy)+bb*fx*(4-fy)+cc*(4-fx)*fy+dd*fx*fy;
 interp=(sum+8)>>4;
 end endfunction
 initial begin
 if ((BITS!=8 && BITS!=10)||WIDTH<1||HEIGHT<1) $fatal(1,"invalid geometry/BITS");
 end
 always @* begin
 // Quarter-chroma units: centered samples have a +1/4 phase.
 nx=2*ox-(hs?1:0); ny=2*oy-(vs?1:0);
 basex=(nx<0)?-1:nx/4; basey=(ny<0)?-1:ny/4;
 fracx=nx-4*basex; fracy=ny-4*basey;
 end
 always @(posedge clk) begin
 if (!rst_n) begin
 state<=CAP;ix<=0;iy<=0;ox<=0;oy<=0;expect_chroma<=0;
 mode<=0;hs<=0;vs<=0;cfg_done<=0;cfg_error<=0;marker_error<=0;
 m_tvalid<=0;m_tdata<=0;m_tuser<=0;m_tlast<=0;
 xa<=0;xb<=0;ya<=0;yb<=0;fx<=0;fy<=0;
 end else if(ce) begin
 cfg_done<=0;cfg_error<=0;
 if(cfg_valid && cfg_ready) begin
 if(cfg_mode>1 || cfg_h_siting>1 || cfg_v_siting>1) cfg_error<=1;
 else begin mode<=cfg_mode[0];hs<=cfg_h_siting[0];vs<=cfg_v_siting[0];cfg_done<=1;end
 end
 case(state)
 CAP: if(s_tvalid && s_tready) begin
 if(s_tdata[2*BITS]!=expect_chroma || s_tuser!=(ix==0&&iy==0&&!expect_chroma) || s_tlast!=final_word) marker_error<=1;
 // Expected beat geometry drives capture even on malformed markers/tags.
 if(expect_chroma) cmem[(iy/2)*CW+ix]<=s_tdata[2*BITS-1:0];
 else ymem[iy*CW+ix]<=s_tdata[2*BITS-1:0];
 if(chroma_line && !expect_chroma) expect_chroma<=1;
 else begin
 expect_chroma<=0;
 if(ix==CW-1) begin ix<=0;
 if(iy==HEIGHT-1) begin iy<=0;ox<=0;oy<=0;state<=ADDRESS;end
 else iy<=iy+1;
 end else ix<=ix+1;
 end
 end
 ADDRESS: begin
 if(mode==0) begin
 // Nearest: ties select the sample at the greater coordinate.
 xa<=((nx+2)/4<0)?0:(((nx+2)/4>=CW)?CW-1:(nx+2)/4);
 xb<=((nx+2)/4<0)?0:(((nx+2)/4>=CW)?CW-1:(nx+2)/4);
 ya<=((ny+2)/4<0)?0:(((ny+2)/4>=CH)?CH-1:(ny+2)/4);
 yb<=((ny+2)/4<0)?0:(((ny+2)/4>=CH)?CH-1:(ny+2)/4);
 fx<=0;fy<=0;
 end else begin
 xa<=basex<0?0:(basex>=CW?CW-1:basex);
 xb<=basex+1<0?0:(basex+1>=CW?CW-1:basex+1);
 ya<=basey<0?0:(basey>=CH?CH-1:basey);
 yb<=basey+1<0?0:(basey+1>=CH?CH-1:basey+1);
 fx<=fracx;fy<=fracy;
 end
 yq<=ymem[oy*CW+ox/2];state<=READ_Y;
 end
 READ_Y: begin luma<=ox[0]?yq[BITS-1:0]:yq[2*BITS-1:BITS];cq<=cmem[ya*CW+xa];state<=READ_A;end
 READ_A: begin a<=cq;cq<=cmem[ya*CW+xb];state<=READ_B;end
 READ_B: begin b<=cq;cq<=cmem[yb*CW+xa];state<=READ_C;end
 READ_C: begin c<=cq;cq<=cmem[yb*CW+xb];state<=READ_D;end
 READ_D: begin d<=cq;state<=EMIT;end
 EMIT: if(!m_tvalid) begin
 m_tdata<={luma,interp(a[2*BITS-1:BITS],b[2*BITS-1:BITS],c[2*BITS-1:BITS],d[2*BITS-1:BITS]),interp(a[BITS-1:0],b[BITS-1:0],c[BITS-1:0],d[BITS-1:0])};
 m_tuser<=ox==0&&oy==0;m_tlast<=ox==WIDTH-1;m_tvalid<=1;
 end else if(m_tready) begin
 m_tvalid<=0;
 if(ox==WIDTH-1) begin ox<=0;if(oy==HEIGHT-1) begin oy<=0;state<=CAP;end else begin oy<=oy+1;state<=ADDRESS;end end
 else begin ox<=ox+1;state<=ADDRESS;end
 end
 endcase
 end
 end
endmodule
