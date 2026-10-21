// Contrast autofocus controller. Frame statistics and actuator transport are external.
module contrast_af_controller #(parameter POS_W=12,METRIC_W=24)(
 input wire clk,rst,ce,
 input wire start_valid,output wire start_ready,input wire abort,
 input wire[POS_W-1:0] cfg_min,cfg_max,cfg_coarse_step,cfg_fine_step,
 input wire[7:0] cfg_settle_frames,cfg_samples,
 input wire[METRIC_W-1:0] cfg_metric_min,cfg_metric_max,
 input wire[31:0] cfg_timeout_cycles,
 output wire act_valid,input wire act_ready,output wire[POS_W-1:0] act_position,
 input wire ack_valid,output wire ack_ready,input wire[POS_W-1:0] ack_position,input wire ack_error,
 input wire metric_valid,output wire metric_ready,input wire[METRIC_W-1:0] metric,
 output wire result_valid,input wire result_ready,output reg[POS_W-1:0] result_position,
 output reg[METRIC_W+7:0] result_score,output reg[7:0] result_samples,
 output reg[3:0] error_code,output wire busy,output reg[31:0] positions_measured,frames_dropped
);
 localparam IDLE=0,CMD=1,ACK=2,COLLECT=3,PARKDROP=4,RESULT=5;
 reg[2:0] state;reg[1:0] phase;
 reg[POS_W-1:0] lo,hi,coarse,fine,current,scan_end,best_pos;
 reg[7:0] settle,samples,drop_left,sample_count;
 reg[METRIC_W-1:0] metric_min,metric_max;
 reg[METRIC_W+7:0] accumulator,best_score;
 reg best_valid;
 reg[31:0] timeout_limit,watchdog;
 wire[METRIC_W+7:0] score=accumulator+metric;
 wire better=!best_valid||score>best_score||(score==best_score&&current<best_pos);
 wire[POS_W-1:0] winning_pos=better?current:best_pos;
 wire[METRIC_W+7:0] winning_score=better?score:best_score;
 wire[POS_W:0] candidate={1'b0,current}+((phase==0)?{1'b0,coarse}:{1'b0,fine});
 wire[POS_W:0] fine_upper={1'b0,winning_pos}+{1'b0,coarse};
 wire[POS_W-1:0] fine_lower=({1'b0,winning_pos}>{1'b0,lo}+{1'b0,coarse})?winning_pos-coarse:lo;
 assign busy=state!=IDLE;
 assign start_ready=ce&&state==IDLE&&!abort;
 assign act_valid=state==CMD&&!abort;
 assign act_position=current;
 assign ack_ready=ce&&state==ACK&&!abort;
 assign metric_ready=ce&&state!=IDLE&&state!=RESULT&&!abort;
 assign result_valid=state==RESULT;
 initial if(POS_W<2||POS_W>16||METRIC_W<2||METRIC_W>32) $fatal(1,"invalid AF parameters");
 task fail;
 input[3:0] code;
 begin error_code<=code;state<=RESULT;end
 endtask
 always @(posedge clk) begin
 if(rst) begin
 state<=IDLE;phase<=0;lo<=0;hi<=0;coarse<=0;fine<=0;current<=0;scan_end<=0;best_pos<=0;
 settle<=0;samples<=0;drop_left<=0;sample_count<=0;metric_min<=0;metric_max<=0;
 accumulator<=0;best_score<=0;best_valid<=0;timeout_limit<=0;watchdog<=0;
 result_position<=0;result_score<=0;result_samples<=0;error_code<=0;positions_measured<=0;frames_dropped<=0;
 end else if(ce) begin
 if(abort&&state!=IDLE&&state!=RESULT) fail(5);
 else begin
 if(metric_valid&&metric_ready&&(state==CMD||state==ACK)) frames_dropped<=frames_dropped+1'b1;
 case(state)
 IDLE: if(start_valid&&start_ready) begin
 result_position<=0;result_score<=0;result_samples<=cfg_samples;error_code<=0;positions_measured<=0;frames_dropped<=0;
 if(cfg_min>cfg_max||cfg_coarse_step==0||cfg_fine_step==0||cfg_fine_step>cfg_coarse_step||cfg_samples==0||cfg_metric_min>cfg_metric_max) fail(1);
 else begin
 lo<=cfg_min;hi<=cfg_max;coarse<=cfg_coarse_step;fine<=cfg_fine_step;settle<=cfg_settle_frames;samples<=cfg_samples;
 metric_min<=cfg_metric_min;metric_max<=cfg_metric_max;timeout_limit<=cfg_timeout_cycles;watchdog<=0;
 current<=cfg_min;scan_end<=cfg_max;phase<=0;best_valid<=0;best_score<=0;accumulator<=0;sample_count<=0;state<=CMD;
 end
 end
 CMD: if(act_ready) begin state<=ACK;watchdog<=0;end
 else if(timeout_limit!=0) begin if(watchdog==timeout_limit-1) fail(6);else watchdog<=watchdog+1'b1;end
 ACK: if(ack_valid&&ack_ready) begin
 watchdog<=0;
 if(ack_error) fail(2);
 else if(ack_position!=current) fail(3);
 else begin
 drop_left<=settle;sample_count<=0;accumulator<=0;
 if(phase==2) begin if(settle==0) state<=RESULT;else state<=PARKDROP;end
 else state<=COLLECT;
 end
 end else if(timeout_limit!=0) begin if(watchdog==timeout_limit-1) fail(6);else watchdog<=watchdog+1'b1;end
 COLLECT: if(metric_valid&&metric_ready) begin
 watchdog<=0;
 if(drop_left!=0) begin drop_left<=drop_left-1'b1;frames_dropped<=frames_dropped+1'b1;end
 else if(metric<metric_min||metric>metric_max) fail(4);
 else if(sample_count==samples-1) begin
 positions_measured<=positions_measured+1'b1;
 if(better) begin best_score<=score;best_pos<=current;best_valid<=1;end
 if(current==scan_end) begin
 if(phase==0) begin
 phase<=1;current<=fine_lower;scan_end<=(fine_upper>{1'b0,hi})?hi:fine_upper[POS_W-1:0];
 end else begin
 phase<=2;current<=winning_pos;result_position<=winning_pos;result_score<=winning_score;
 end
 end else current<=candidate>={1'b0,scan_end}?scan_end:candidate[POS_W-1:0];
 state<=CMD;watchdog<=0;
 end else begin sample_count<=sample_count+1'b1;accumulator<=score;end
 end else if(timeout_limit!=0) begin if(watchdog==timeout_limit-1) fail(6);else watchdog<=watchdog+1'b1;end
 PARKDROP: if(metric_valid&&metric_ready) begin
 watchdog<=0;frames_dropped<=frames_dropped+1'b1;
 if(drop_left==1) state<=RESULT;else drop_left<=drop_left-1'b1;
 end else if(timeout_limit!=0) begin if(watchdog==timeout_limit-1) fail(6);else watchdog<=watchdog+1'b1;end
 RESULT: if(result_ready) state<=IDLE;
 default: state<=IDLE;
 endcase
 end
 end
 end
endmodule
