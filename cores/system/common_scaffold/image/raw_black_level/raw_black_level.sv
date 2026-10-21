// Original four-plane RAW black-level correction. Same-frame optical-black ROI.
module raw_black_level #(
 parameter integer WIDTH=32, HEIGHT=24, BITS=8
)(
 input wire clk,rst_n,ce,start_valid, output wire start_ready,
 input wire cfg_auto, input wire[1:0] cfg_pattern,
 input wire[4*BITS-1:0] cfg_black_levels,
 input wire[BITS-1:0] cfg_target_pedestal,
 input wire[15:0] cfg_roi_x,cfg_roi_y,cfg_roi_width,cfg_roi_height,
 input wire abort,
 input wire[BITS-1:0] s_data, input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output wire[BITS-1:0] m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[7:0] error_code,output wire busy,
 output wire[127:0] stats_sums,stats_counts,
 output wire[4*BITS-1:0] stats_mean_levels,applied_black_levels,
 output reg[31:0] clip_low_count,clip_high_count
);
 localparam integer N=(WIDTH>0&&HEIGHT>0)?WIDTH*HEIGHT:1,AW=$clog2(N+1);
 localparam IDLE=0,CAPTURE=1,MEAN_INIT=2,DIVIDE=3,MEAN_SAVE=4,READ=5,APPLY=6,HOLD=7,DONE=8;
 reg[3:0] state;
 reg[BITS-1:0] frame[0:N-1],sample_q,out_q,target;
 reg[AW-1:0] in_pos,out_pos;
 reg[15:0] in_x,in_y,out_x,out_y,roi_x,roi_y,roi_w,roi_h;
 reg[1:0] pattern,plane;
 reg auto_mode,clip_low_q,clip_high_q;
 reg[31:0] sums[0:3],counts[0:3];
 reg[BITS-1:0] means[0:3],blacks[0:3];
 reg[31:0] numerator,denominator,quotient,remainder;
 reg[5:0] divide_steps;
 integer i;
 function[1:0] cfa_plane;
 input x,y;input[1:0]p;
 begin
 if(y==p[1])begin if(x==p[0])cfa_plane=0;else cfa_plane=1;end
 else begin if(x==p[0])cfa_plane=2;else cfa_plane=3;end
 end endfunction
 wire[1:0] in_plane=cfa_plane(in_x[0],in_y[0],pattern);
 wire[1:0] out_plane=cfa_plane(out_x[0],out_y[0],pattern);
 wire in_roi=in_x>=roi_x&&in_y>=roi_y&&{1'b0,in_x}<{1'b0,roi_x}+{1'b0,roi_w}&&{1'b0,in_y}<{1'b0,roi_y}+{1'b0,roi_h};
 wire[32:0] trial={remainder,numerator[31]};
 wire trial_ge=trial>={1'b0,denominator};
 wire signed[BITS+1:0] corrected=$signed({2'b0,sample_q})-$signed({2'b0,blacks[out_plane]})+$signed({2'b0,target});
 genvar g;generate for(g=0;g<4;g=g+1)begin: STAT
 assign stats_sums[32*g+:32]=sums[g];assign stats_counts[32*g+:32]=counts[g];
 assign stats_mean_levels[BITS*g+:BITS]=means[g];assign applied_black_levels[BITS*g+:BITS]=blacks[g];
 end endgenerate
 assign start_ready=rst_n&&ce&&!abort&&state==IDLE;
 assign s_ready=rst_n&&ce&&!abort&&state==CAPTURE;
 assign m_valid=state==HOLD&&!abort;assign m_data=out_q;
 assign m_sof=out_pos==0;assign m_eol=out_x==WIDTH-1;assign m_last=out_pos==N-1;
 assign done_valid=state==DONE;assign busy=state!=IDLE&&state!=DONE;
 task fail;input[7:0]code;begin state<=DONE;done_error<=1;error_code<=code;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin
 state<=IDLE;done_error<=0;error_code<=0;in_pos<=0;out_pos<=0;in_x<=0;in_y<=0;out_x<=0;out_y<=0;
 pattern<=0;auto_mode<=0;target<=0;roi_x<=0;roi_y<=0;roi_w<=0;roi_h<=0;plane<=0;
 clip_low_count<=0;clip_high_count<=0;clip_low_q<=0;clip_high_q<=0;
 numerator<=0;denominator<=0;quotient<=0;remainder<=0;divide_steps<=0;
 for(i=0;i<4;i=i+1)begin sums[i]<=0;counts[i]<=0;means[i]<=0;blacks[i]<=0;end
 end else if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE)fail(8'h93);
 else case(state)
 IDLE:if(start_valid&&!abort)begin
 done_error<=0;error_code<=0;in_pos<=0;out_pos<=0;in_x<=0;in_y<=0;out_x<=0;out_y<=0;
 pattern<=cfg_pattern;auto_mode<=cfg_auto;target<=cfg_target_pedestal;
 roi_x<=cfg_roi_x;roi_y<=cfg_roi_y;roi_w<=cfg_roi_width;roi_h<=cfg_roi_height;
 clip_low_count<=0;clip_high_count<=0;plane<=0;
 for(i=0;i<4;i=i+1)begin sums[i]<=0;counts[i]<=0;means[i]<=0;blacks[i]<=cfg_black_levels[i*BITS+:BITS];end
 if(WIDTH<1||HEIGHT<1||WIDTH>256||HEIGHT>256||(BITS!=8&&BITS!=10&&BITS!=12))fail(8'h80);
 else if(cfg_auto&&(cfg_roi_width==0||cfg_roi_height==0||
 {1'b0,cfg_roi_x}+{1'b0,cfg_roi_width}>WIDTH||{1'b0,cfg_roi_y}+{1'b0,cfg_roi_height}>HEIGHT))fail(8'h82);
 else state<=CAPTURE;
 end
 CAPTURE:if(s_valid)begin
 if(s_sof!=(in_pos==0)||s_eol!=(in_x==WIDTH-1)||s_last!=(in_pos==N-1))fail(8'h81);
 else begin
 frame[in_pos]<=s_data;
 if(auto_mode&&in_roi)begin sums[in_plane]<=sums[in_plane]+s_data;counts[in_plane]<=counts[in_plane]+1'b1;end
 if(in_pos==N-1)begin if(auto_mode)state<=MEAN_INIT;else state<=READ;end
 else begin in_pos<=in_pos+1'b1;if(in_x==WIDTH-1)begin in_x<=0;in_y<=in_y+1'b1;end else in_x<=in_x+1'b1;end
 end end
 MEAN_INIT:begin
 if(counts[plane]==0)fail(8'h83);
 else begin numerator<=sums[plane]+(counts[plane]>>1);denominator<=counts[plane];quotient<=0;remainder<=0;divide_steps<=32;state<=DIVIDE;end
 end
 DIVIDE:begin
 numerator<={numerator[30:0],1'b0};quotient<={quotient[30:0],trial_ge};
 if(trial_ge)remainder<=trial-denominator;else remainder<=trial[31:0];
 if(divide_steps==1)state<=MEAN_SAVE;else divide_steps<=divide_steps-1'b1;
 end
 MEAN_SAVE:begin means[plane]<=quotient[BITS-1:0];blacks[plane]<=quotient[BITS-1:0];
 if(plane==3)state<=READ;else begin plane<=plane+1'b1;state<=MEAN_INIT;end end
 READ:begin sample_q<=frame[out_pos];state<=APPLY;end
 APPLY:begin
 clip_low_q<=corrected<0;clip_high_q<=corrected>((1<<BITS)-1);
 if(corrected<0)out_q<=0;else if(corrected>((1<<BITS)-1))out_q<={BITS{1'b1}};else out_q<=corrected[BITS-1:0];
 state<=HOLD;end
 HOLD:if(m_ready)begin
 if(clip_low_q)clip_low_count<=clip_low_count+1'b1;if(clip_high_q)clip_high_count<=clip_high_count+1'b1;
 if(out_pos==N-1)state<=DONE;
 else begin out_pos<=out_pos+1'b1;if(out_x==WIDTH-1)begin out_x<=0;out_y<=out_y+1'b1;end else out_x<=out_x+1'b1;state<=READ;end
 end
 DONE:if(done_ready)state<=IDLE;
 default:fail(8'h94);
 endcase end end
endmodule
