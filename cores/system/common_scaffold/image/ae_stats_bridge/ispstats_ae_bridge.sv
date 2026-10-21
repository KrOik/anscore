// Gray (CH=1) ispstats result RAM -> img_ae_controller statistics handshake.
// This adapter runs every clock, including when the AE clk_en is low.
module ispstats_ae_bridge #(
 parameter CNTW=10, SUMW=18, ENW=19,
 parameter RW=2*CNTW+3*SUMW+ENW
)(
 input wire clk, rst_n,
 input wire res_new, res_new_bank,
 input wire [6:0] frame_records,
 input wire [31:0] frame_id,
 input wire frame_error,
 input wire [1:0] res_done,
 output reg res_bank,
 output reg [5:0] res_addr,
 input wire [RW-1:0] res_data,
 output wire stats_valid, input wire stats_ready,
 output reg [47:0] stats_luma_sum,
 output reg [31:0] stats_count, stats_saturated, stats_frame_id,
 output reg stats_overflow,
 output reg overrun, output reg [31:0] dropped_frames
);
 localparam IDLE=0, WAIT_READ=1, ACCUMULATE=2, OUTPUT=3;
 reg [1:0] state;
 reg [6:0] remaining;
 wire [CNTW-1:0] rec_count=res_data[0 +: CNTW];
 wire [SUMW-1:0] rec_sum=res_data[CNTW +: SUMW];
 wire [CNTW-1:0] rec_sat=res_data[CNTW+3*SUMW +: CNTW];
 wire [48:0] next_sum={1'b0,stats_luma_sum}+rec_sum;
 wire [32:0] next_count={1'b0,stats_count}+rec_count;
 wire [32:0] next_sat={1'b0,stats_saturated}+rec_sat;
 assign stats_valid=state==OUTPUT;
 initial begin
  if(CNTW<1 || CNTW>32 || SUMW<1 || SUMW>48 || ENW<1 ||
     RW!=2*CNTW+3*SUMW+ENW) $fatal(1,"invalid statistics widths");
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE; remaining<=0; res_bank<=0; res_addr<=0;
   stats_luma_sum<=0; stats_count<=0; stats_saturated<=0;
   stats_frame_id<=0; stats_overflow<=0; overrun<=0; dropped_frames<=0;
  end else begin
   case(state)
    WAIT_READ: state<=ACCUMULATE;
    ACCUMULATE: begin
     stats_luma_sum<=next_sum[47:0]; stats_count<=next_count[31:0];
     stats_saturated<=next_sat[31:0];
     if(!res_done[res_bank] || next_sum[48] || next_count[32] || next_sat[32] ||
        rec_count==0 || rec_sat>rec_count) stats_overflow<=1;
     if(remaining==1) state<=OUTPUT;
     else begin remaining<=remaining-1'b1; res_addr<=res_addr+1'b1; state<=WAIT_READ; end
    end
    OUTPUT: if(stats_ready) state<=IDLE;
    default: state<=IDLE;
   endcase
   if(res_new) begin
    if(state==IDLE || (state==OUTPUT && stats_ready)) begin
     res_bank<=res_new_bank; res_addr<=0; remaining<=frame_records;
     stats_frame_id<=frame_id; stats_count<=0; stats_luma_sum<=0; stats_saturated<=0;
     stats_overflow<=frame_error || frame_records==0 || frame_records>64;
     if(frame_records==0 || frame_records>64) state<=OUTPUT;
     else state<=WAIT_READ;
    end else begin
     overrun<=1; dropped_frames<=dropped_frames+1'b1;
     // Reuse of the bank being read invalidates that pending measurement.
     if(state!=OUTPUT && res_new_bank==res_bank) stats_overflow<=1;
    end
   end
  end
 end
endmodule
