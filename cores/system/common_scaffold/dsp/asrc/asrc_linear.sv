// Real dual-clock fractional linear ASRC. No automatic clock-ratio estimator.
module asrc_async_fifo #(parameter BITS=16, ADDR=4)(
 input wire arst_n,wclk,rclk,
 input wire [BITS-1:0] wdata,input wire wvalid,output wire wready,
 input wire ren,output reg [BITS-1:0] rdata,output reg rvalid,
 output wire empty,output reg overflow
);
 reg [BITS-1:0] mem[0:(1<<ADDR)-1];
 reg [ADDR:0] wp,rp,wg,rg;
 (* async_reg="true" *) reg [ADDR:0] rg1,rg2,wg1,wg2;
 (* async_reg="true" *) reg [1:0] wrst,rrst;
 wire wn=wrst[1],rn=rrst[1];
 wire [ADDR:0] wnext=wp+1'b1;
 wire [ADDR:0] wgray=(wnext>>1)^wnext;
 wire full=wg=={~rg2[ADDR:ADDR-1],rg2[ADDR-2:0]};
 assign wready=wn&&!full;
 assign empty=!rn || rg==wg2;
 always @(posedge wclk or negedge arst_n)
 if(!arst_n) wrst<=0;else wrst<={wrst[0],1'b1};
 always @(posedge rclk or negedge arst_n)
 if(!arst_n) rrst<=0;else rrst<={rrst[0],1'b1};
 always @(posedge wclk or negedge arst_n) begin
 if(!arst_n) begin wp<=0;wg<=0;rg1<=0;rg2<=0;overflow<=0;end
 else if(!wn) begin wp<=0;wg<=0;rg1<=0;rg2<=0;overflow<=0;end
 else begin
 rg1<=rg;rg2<=rg1;
 if(wvalid && !wready) overflow<=1;
 if(wvalid&&wready) begin mem[wp[ADDR-1:0]]<=wdata;wp<=wnext;wg<=wgray;end
 end end
 always @(posedge rclk or negedge arst_n) begin
 if(!arst_n) begin rp<=0;rg<=0;wg1<=0;wg2<=0;rvalid<=0;rdata<=0;end
 else if(!rn) begin rp<=0;rg<=0;wg1<=0;wg2<=0;rvalid<=0;end
 else begin
 wg1<=wg;wg2<=wg1;rvalid<=0;
 if(ren&&!empty) begin rdata<=mem[rp[ADDR-1:0]];rp<=rp+1'b1;rg<=((rp+1'b1)>>1)^(rp+1'b1);rvalid<=1;end
 end end
 initial if(ADDR<2 || BITS<2) $fatal(1,"invalid FIFO parameters");
endmodule

module asrc_linear #(parameter BITS=16, FRAC=12, FIFO_ADDR=4)(
 input wire arst_n,in_clk,out_clk,
 input wire signed [BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 output reg signed [BITS-1:0] m_data,output reg m_valid,input wire m_ready,
 input wire cfg_valid,output wire cfg_ready,input wire [FRAC+2:0] cfg_step,
 output reg cfg_done,cfg_error,output wire overflow,output reg underflow
);
 // step is input samples / output sample, unsigned Q3.FRAC, 0 < step < 8.
 localparam GET_A=0,WAIT_A=1,GET_B=2,WAIT_B=3,EMIT=4,ADVANCE=5;
 reg [2:0] state;
 (* async_reg="true" *) reg [1:0] reset_release;
 wire active=reset_release[1];
 wire empty,rv;wire [BITS-1:0] rd;
 wire ren=active && !empty && (state==GET_A||state==GET_B);
 reg signed [BITS-1:0] a,b;
 reg [FRAC+3:0] phase;
 reg [FRAC+2:0] step;
 wire signed [BITS:0] delta=$signed({b[BITS-1],b})-$signed({a[BITS-1],a});
 wire signed [BITS+FRAC+1:0] product=delta*$signed({1'b0,phase[FRAC-1:0]});
 wire signed [BITS+FRAC+2:0] rounded=product+(1<<(FRAC-1));
 wire signed [BITS+1:0] result=$signed(a)+(rounded>>>FRAC);
 assign cfg_ready=active&&!m_valid;
 asrc_async_fifo #(.BITS(BITS),.ADDR(FIFO_ADDR)) fifo(arst_n,in_clk,out_clk,s_data,s_valid,s_ready,ren,rd,rv,empty,overflow);
 always @(posedge out_clk or negedge arst_n)
 if(!arst_n) reset_release<=0;else reset_release<={reset_release[0],1'b1};
 always @(posedge out_clk or negedge arst_n) begin
 if(!arst_n) begin state<=GET_A;a<=0;b<=0;phase<=0;step<=(1<<FRAC);m_data<=0;m_valid<=0;underflow<=0;cfg_done<=0;cfg_error<=0;end
 else if(!active) begin state<=GET_A;phase<=0;m_valid<=0;cfg_done<=0;cfg_error<=0;end
 else begin
 cfg_done<=0;cfg_error<=0;
 if(cfg_valid&&cfg_ready) begin
 if(cfg_step==0) cfg_error<=1;
 else begin step<=cfg_step;cfg_done<=1;end
 end
 case(state)
 GET_A: if(!empty) state<=WAIT_A;else underflow<=1;
 WAIT_A: if(rv) begin a<=rd;state<=GET_B;end
 GET_B: if(!empty) state<=WAIT_B;else underflow<=1;
 WAIT_B: if(rv) begin b<=rd;state<=ADVANCE;end
 ADVANCE: if(phase >= (1<<FRAC)) begin phase<=phase-(1<<FRAC);a<=b;state<=GET_B;end else state<=EMIT;
 EMIT: if(!m_valid) begin m_data<=result[BITS-1:0];m_valid<=1;end
 else if(m_ready) begin m_valid<=0;phase<=phase+step;state<=ADVANCE;end
 endcase
 end end
 initial if(BITS<2||BITS>24||FRAC<2||FRAC>20||FIFO_ADDR<2) $fatal(1,"invalid ASRC parameters");
endmodule
