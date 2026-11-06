// Pipelined unsigned bitonic sorting network. Padding sentinels are maxima.
module median_network #(parameter BITS=8,K=3)(
 input wire clk,rst_n,input wire [K*K*BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,output wire s_tready,
 output wire [BITS-1:0] m_tdata,output wire m_tvalid,m_tuser,m_tlast,input wire m_tready
);
 localparam LOG=(K==3)?4:5,N=1<<LOG,STAGES=LOG*(LOG+1)/2;
 wire [N*BITS-1:0] data[0:STAGES];
 reg [STAGES-1:0] valid,sof,eol;
 wire advance=!valid[STAGES-1] || m_tready;
 assign s_tready=advance;
 assign data[0]={{((N-K*K)*BITS){1'b1}},s_tdata};
 assign m_tdata=data[STAGES][((K*K)/2)*BITS+:BITS];
 assign m_tvalid=valid[STAGES-1];assign m_tuser=sof[STAGES-1];assign m_tlast=eol[STAGES-1];
 always @(posedge clk) begin
 if(!rst_n) begin valid<=0;sof<=0;eol<=0;end
 else if(advance) begin valid<={valid[STAGES-2:0],s_tvalid};sof<={sof[STAGES-2:0],s_tuser};eol<={eol[STAGES-2:0],s_tlast};end
 end
 genvar l,j,p;
 generate for(l=1;l<=LOG;l=l+1) begin: level
 for(j=0;j<l;j=j+1) begin: step
 localparam DIST=1<<(l-1-j),S=l*(l-1)/2+j;
 wire stage_valid;
 if(S==0) assign stage_valid=s_tvalid;else assign stage_valid=valid[S-1];
 for(p=0;p<N/2;p=p+1) begin: pair
 localparam A=(p/DIST)*(2*DIST)+(p%DIST),B=A+DIST,ASCENDING=((A & (1<<l))==0);
 wire [BITS-1:0] a=data[S][A*BITS+:BITS],b=data[S][B*BITS+:BITS];
 wire ordered=ASCENDING ? (a<=b):(a>=b);
 reg [BITS-1:0] aq,bq;
 always @(posedge clk) if(rst_n && advance && stage_valid) begin aq<=ordered?a:b;bq<=ordered?b:a;end
 assign data[S+1][A*BITS+:BITS]=aq;assign data[S+1][B*BITS+:BITS]=bq;
 end end end endgenerate
 initial if((BITS!=8 && BITS!=10)||(K!=3 && K!=5))$fatal(1,"unsupported median_network parameters");
endmodule
