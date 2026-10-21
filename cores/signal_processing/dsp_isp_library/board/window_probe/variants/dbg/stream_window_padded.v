// Row-buffered centered ZERO/REPLICATE windows, reusing the VALID line engine.
// Capture one row, then replay its extended raster row(s); no frame buffer.
module stream_window_padded #(
 parameter DATA_WIDTH=8, WIDTH=32, HEIGHT=24, K=3,
 parameter PAD_MODE=0, MAX_WIDTH=4096 // 0=ZERO, 1=REPLICATE
)(
 input wire clk,rst_n,
 input wire [DATA_WIDTH-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,output wire s_tready,
 output wire [K*K*DATA_WIDTH-1:0] m_tdata,
 output wire m_tvalid,m_tuser,m_tlast,input wire m_tready,
 output reg marker_error
);
 localparam R=K/2, PW=WIDTH+K-1, PH=HEIGHT+K-1;
 localparam XW=(WIDTH<2)?1:$clog2(WIDTH);
 localparam YW=(HEIGHT<2)?1:$clog2(HEIGHT);
 localparam PXW=$clog2(PW), PYW=$clog2(PH);
 localparam OW=(WIDTH*HEIGHT<2)?1:$clog2(WIDTH*HEIGHT);
 localparam CAPTURE=0,REPLAY=1,DRAIN=2;
 reg [1:0] state;
 reg [XW-1:0] x;
 reg [YW-1:0] y;
 reg [PXW-1:0] rx;
 reg [PYW-1:0] ry;
 reg [OW-1:0] output_count;
 reg pending,pzero,psof,peol;
 reg rv,ru,rl;
 reg [DATA_WIDTH-1:0] rd;
 wire rr,core_error;
 wire advance=!rv || rr;
 wire issue=state==REPLAY && advance;
 wire take=s_tvalid && s_tready;
 assign s_tready=rst_n && state==CAPTURE;
 integer sx,sy;
 reg outside;
 reg [PXW-1:0] ridx;
 always @* begin
   sx=$signed({1'b0,rx})-R;sy=$signed({1'b0,ry})-R;
   outside=(sx<0 || sx>=WIDTH || sy<0 || sy>=HEIGHT);
   if(sy<0)sy=0;else if(sy>=HEIGHT)sy=HEIGHT-1;
   if(rx<=R) ridx={PXW{1'b0}};
   else if(rx-R>=WIDTH) ridx=WIDTH[PXW-1:0]-1'b1;
   else ridx=rx-R;
 end
 wire pzero_shadow=(PAD_MODE==0)&&outside;
 (* ram_style="block" *) reg [DATA_WIDTH-1:0] row_mem[0:WIDTH-1];
 reg [DATA_WIDTH-1:0] row_q;
 reg [DATA_WIDTH-1:0] first_pix;
 // debug: internals captured at issue edge, re-registered with rd at pending edge
 reg [PXW-1:0] rx_i,ridx_i; reg [PYW-1:0] ry_i; reg out_i,pz_i;
 reg [PXW-1:0] rx_d,ridx_d; reg [PYW-1:0] ry_d; reg out_d,pz_d;
 // Capture/replay separation precludes read/write collisions entirely.
 always @(posedge clk) begin
   if(rst_n && take)row_mem[x]<=s_tdata;
   if(rst_n && take && x=={XW{1'b0}})first_pix<=s_tdata;
   if(rst_n && issue)begin
     row_q<=row_mem[ridx];
     rx_i<=rx;ry_i<=ry;ridx_i<=ridx;out_i<=outside;pz_i<=pzero_shadow;
   end
 end
 // DEBUG: bypass inner window; export raw replay stream with internals.
 assign rr=m_tready;
 assign core_error=1'b0;
 assign m_tdata={{(K*K*DATA_WIDTH-51){1'b0}},
   rd,first_pix,row_q,pz_d,out_d,ridx_d,ry_d[3:0],rx_d};
 assign m_tvalid=rv;
 assign m_tuser=ru;
 assign m_tlast=rl;
 always @(posedge clk) begin
   if(!rst_n)begin
     state<=CAPTURE;x<=0;y<=0;rx<=0;ry<=0;output_count<=0;
     pending<=0;rv<=0;ru<=0;rl<=0;marker_error<=0;
   end else begin
     if(core_error)marker_error<=1;
     if(take)begin
       if(s_tuser!=((x==0)&&(y==0)) || s_tlast!=(x==WIDTH-1))marker_error<=1;
       if(x==WIDTH-1)begin
         x<=0;
         state<=REPLAY;
         if(y==HEIGHT-1)begin y<=0;end
         else y<=y+1'b1;
       end else x<=x+1'b1;
     end
     if(advance)begin
       pending<=issue;rv<=pending;
       if(pending)begin
         rd<=pzero?{DATA_WIDTH{1'b0}}:row_q;
         ru<=psof;rl<=peol;
         rx_d<=rx_i;ry_d<=ry_i;ridx_d<=ridx_i;out_d<=out_i;pz_d<=pz_i;
       end
       if(issue)begin
         pzero<=(PAD_MODE==0)&&outside;
         psof<=(rx==0)&&(ry==0);peol<=(rx==PW-1);
         if(rx==PW-1)begin
           rx<=0;
           if(ry==PH-1)begin ry<=0;state<=DRAIN;end
           else begin
             ry<=ry+1'b1;
             // Top and bottom padding replay the first/last cached row.
             // Otherwise pause replay until the next source row is captured.
             if(ry>=R && ry<R+HEIGHT-1)state<=CAPTURE;
           end
         end else rx<=rx+1'b1;
       end
     end
     if(m_tvalid && m_tready)begin
       if(output_count==WIDTH*HEIGHT-1)begin output_count<=0;state<=CAPTURE;rx<=0;ry<=0;end
       else output_count<=output_count+1'b1;
     end
   end
 end
 initial begin
   if((K!=3 && K!=5) || WIDTH<1 || HEIGHT<1 || DATA_WIDTH<1 || DATA_WIDTH>16 ||
      (PAD_MODE!=0 && PAD_MODE!=1) || MAX_WIDTH<1 || WIDTH>MAX_WIDTH)
     $fatal(1,"unsupported stream_window_padded parameters");
 end
endmodule
