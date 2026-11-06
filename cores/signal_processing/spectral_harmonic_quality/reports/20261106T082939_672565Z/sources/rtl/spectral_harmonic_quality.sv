// SPDX-License-Identifier: Apache-2.0
// Original harmonic-window instrument; canonical arithmetic helpers are unchanged.
module spectral_harmonic_quality #(
 parameter integer MAX_LOG2N=8, MAX_HARMONICS=8, TAG_W=8,
 localparam integer SUM_W=32+MAX_LOG2N-1,
 localparam integer RATIO_W=SUM_W+17
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [31:0]c_log2n,c_harmonics,c_radius,c_search_low,c_search_high,
 input wire [TAG_W-1:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[31:0]s_power,
 input wire s_last,s_invalid,
 output wire m_valid,input wire m_ready,output reg[2:0]m_status,
 output reg[TAG_W-1:0]m_tag,
 output reg[31:0]m_log2n,m_harmonics,m_radius,m_search_low,m_search_high,
 output reg[12:0]m_received,
 output reg[31:0]m_fund_bin,m_peak_power,
 output reg[SUM_W-1:0]m_total,m_fund,m_harm,m_residual,
 output reg[MAX_HARMONICS*SUM_W-1:0]m_components,
 output reg[RATIO_W-1:0]m_thd2_q16,m_snr_q16,m_sinad_q16,
 output reg[2:0]m_ratio_valid
);
 localparam integer HALF_CAP=1<<(MAX_LOG2N-1);
 localparam integer AW=SUM_W+1;
 localparam [4:0]IDLE=0,PK_CFG=1,PK_CFG_WAIT=2,LOAD=3,PK_WAIT=4,
   WINDOWS=5,BAND_CFG=6,REPLAY=7,BANDS=8,RESIDUAL=9,
   DIV_SEND=10,DIV_WAIT=11,OUTPUT=12;
 reg[4:0]state;
 reg support_reset_n;
 reg[31:0]power_ram[0:HALF_CAP-1];
 reg[MAX_LOG2N:0]length,half_length,read_issued,read_sent;
 reg[MAX_LOG2N-1:0]input_index;
 reg[3:0]log2n,harmonics,window_h;
 reg[1:0]radius,division;
 reg[31:0]search_low,search_high;
 reg invalid_seen;
 reg[31:0]read_data;
 reg read_valid;
 reg[31:0]window_center;
 reg[32*MAX_HARMONICS-1:0]band_low,band_high;
 wire pk_cfg_ready,pk_cfg_done,pk_cfg_error,pk_input_ready,pk_valid,pk_thr;
 wire[47:0]pk_data;
 wire input_fire=s_valid &&s_ready;
 wire in_search=input_index>=search_low &&input_index<=search_high;
 wire[31:0]pk_power=in_search?s_power:32'd0;
 wire[35:0]command_last_center=c_search_high*{28'd0,c_harmonics[3:0]};
 wire[35:0]command_top=command_last_center+{4'd0,c_radius};
 wire[32:0]command_spacing=({1'b0,c_radius}<<1)+33'd1;
 wire[32:0]command_half=33'd1<<((c_log2n>=1 &&c_log2n<=12)?(c_log2n-1'b1):0);
 wire bad_config=c_log2n<4 ||c_log2n>MAX_LOG2N ||c_harmonics<2 ||
   c_harmonics>MAX_HARMONICS ||c_radius>2 ||c_search_low>c_search_high ||
   {1'b0,c_search_low}<command_spacing ||command_top>={3'd0,command_half};
 wire band_c_ready,band_s_ready,band_valid,band_last;
 wire[1:0]band_status;
 wire[31:0]band_index,band_lo_unused,band_hi_unused,band_peak_unused,band_peak_bin_unused,band_above_unused;
 wire[SUM_W-1:0]band_energy;
 wire[32+2*(MAX_LOG2N-1)-1:0]band_moment_unused;
 wire[TAG_W-1:0]band_tag;
 wire div_ready,div_valid;
 wire[RATIO_W-1:0]div_data;
 wire[1:0]div_flags;
 wire[SUM_W-1:0]div_a=(division==0)?m_harm:m_fund;
 wire[SUM_W-1:0]div_b=(division==0)?m_fund:
   (division==1)?m_residual:(m_harm+m_residual);
 wire[SUM_W-1:0]partition_sum=m_fund+m_harm;
 wire[SUM_W-1:0]extended_power={{(SUM_W-32){1'b0}},s_power};
 assign c_ready=!rst &&support_reset_n &&state==IDLE;
 assign s_ready=!rst &&support_reset_n &&state==LOAD &&pk_input_ready;
 assign m_valid=!rst &&state==OUTPUT;

 // Registered synchronous active-low helper reset fence; band reset is high.
 always @(posedge clk)begin
   if(rst ||(state==OUTPUT &&m_status!=0))support_reset_n<=0;
   else support_reset_n<=1;
 end
 peak_search #(.MAX_LOG2N(MAX_LOG2N)) peak(
   .clk(clk),.rst_n(support_reset_n),.s_tdata(pk_power),
   .s_tvalid(!rst &&state==LOAD &&s_valid),.s_tready(pk_input_ready),
   .m_tdata(pk_data),.m_tuser(pk_thr),.m_tvalid(pk_valid),.m_tready(state==PK_WAIT),
   .cfg_valid(state==PK_CFG),.cfg_ready(pk_cfg_ready),.cfg_log2n(log2n),
   .cfg_thr_en(2'd0),.cfg_threshold(32'd0),.cfg_done(pk_cfg_done),.cfg_error(pk_cfg_error));
 spectral_band_monitor #(.MAX_BINS(HALF_CAP),.BANDS(MAX_HARMONICS),.TAG_W(TAG_W)) bands(
   .clk(clk),.rst(rst ||!support_reset_n),.c_valid(state==BAND_CFG),.c_ready(band_c_ready),
   .c_bins({{(31-MAX_LOG2N){1'b0}},half_length}),.c_threshold(32'd0),
   .c_low(band_low),.c_high(band_high),.c_tag(m_tag),
   .s_valid(state==REPLAY &&read_valid),.s_ready(band_s_ready),.s_power(read_data),
   .m_valid(band_valid),.m_ready(state==BANDS),.m_status(band_status),.m_band(band_index),
   .m_low(band_lo_unused),.m_high(band_hi_unused),.m_energy(band_energy),
   .m_moment(band_moment_unused),.m_peak_power(band_peak_unused),
   .m_peak_bin(band_peak_bin_unused),.m_above(band_above_unused),.m_last(band_last),.m_tag(band_tag));
 fp_div_iter #(.AW(AW),.BW(AW),.FB(16),.OUT_W(RATIO_W)) divider(
   .clk(clk),.rst_n(support_reset_n),.s_tdata({1'b0,div_b,1'b0,div_a}),
   .s_tvalid(state==DIV_SEND &&div_b!=0),.s_tready(div_ready),
   .m_tdata(div_data),.m_tuser(div_flags),.m_tvalid(div_valid),.m_tready(state==DIV_WAIT));

 task fail;
   input[2:0]code;
   begin
     m_status<=code;m_fund_bin<=0;m_peak_power<=0;m_total<=0;m_fund<=0;m_harm<=0;m_residual<=0;
     m_components<=0;m_thd2_q16<=0;m_snr_q16<=0;m_sinad_q16<=0;m_ratio_valid<=0;state<=OUTPUT;
   end
 endtask

 // Synchronous read port, with one elastic read register; collection and replay
 // never overlap. Bin zero is overwritten with zero, independent of source DC.
 always @(posedge clk)begin
   if(input_fire &&input_index<half_length)
     power_ram[input_index[MAX_LOG2N-2:0]]<=(input_index==0)?32'd0:s_power;
   if(state==REPLAY &&(!read_valid ||band_s_ready) &&read_issued<half_length)
     read_data<=power_ram[read_issued[MAX_LOG2N-2:0]];
 end
 always @(posedge clk)begin
   if(rst)begin
     state<=IDLE;length<=0;half_length<=0;read_issued<=0;read_sent<=0;input_index<=0;
     log2n<=4;harmonics<=2;radius<=0;division<=0;search_low<=0;search_high<=0;
     invalid_seen<=0;read_valid<=0;window_h<=1;window_center<=0;band_low<=0;band_high<=0;
     m_status<=0;m_tag<=0;m_log2n<=0;m_harmonics<=0;m_radius<=0;m_search_low<=0;m_search_high<=0;
     m_received<=0;m_fund_bin<=0;m_peak_power<=0;m_total<=0;m_fund<=0;m_harm<=0;m_residual<=0;
     m_components<=0;m_thd2_q16<=0;m_snr_q16<=0;m_sinad_q16<=0;m_ratio_valid<=0;
   end else case(state)
     IDLE:if(c_valid &&c_ready)begin
       m_tag<=c_tag;m_log2n<=c_log2n;m_harmonics<=c_harmonics;m_radius<=c_radius;
       m_search_low<=c_search_low;m_search_high<=c_search_high;m_received<=0;
       m_status<=0;m_fund_bin<=0;m_peak_power<=0;m_total<=0;m_fund<=0;m_harm<=0;m_residual<=0;
       m_components<=0;m_thd2_q16<=0;m_snr_q16<=0;m_sinad_q16<=0;m_ratio_valid<=0;
       invalid_seen<=0;input_index<=0;read_valid<=0;division<=0;
       if(bad_config)fail(3'd1);
       else begin
         log2n<=c_log2n[3:0];harmonics<=c_harmonics[3:0];radius<=c_radius[1:0];
         search_low<=c_search_low;search_high<=c_search_high;
         length<=(13'd1<<c_log2n);half_length<=(13'd1<<(c_log2n-1'b1));state<=PK_CFG;
       end
     end
     PK_CFG:if(pk_cfg_ready)state<=PK_CFG_WAIT;
     PK_CFG_WAIT:if(pk_cfg_done)begin
       if(pk_cfg_error)fail(3'd6);
       else state<=LOAD;
     end
     LOAD:if(input_fire)begin
       m_received<=m_received+1'b1;invalid_seen<=invalid_seen ||s_invalid;
       if(input_index!=0 &&input_index<half_length)m_total<=m_total+extended_power;
       if(s_last &&input_index!=length-1'b1)begin
         fail(3'd2);
       end else if(input_index==length-1'b1)begin
         if(!s_last)fail(3'd3);
         else if(invalid_seen ||s_invalid)fail(3'd4);
         else state<=PK_WAIT;
       end else input_index<=input_index+1'b1;
     end
     PK_WAIT:if(pk_valid)begin
       if(pk_data[31:0]==0)fail(3'd5);
       else begin
         m_fund_bin<={16'd0,pk_data[47:32]};m_peak_power<=pk_data[31:0];
         window_h<=1;window_center<={16'd0,pk_data[47:32]};
         band_low<=0;band_high<=0;state<=WINDOWS;
       end
     end
     WINDOWS:begin
       if(window_h<=harmonics)begin
         band_low[32*(window_h-1)+:32]<=window_center-{30'd0,radius};
         band_high[32*(window_h-1)+:32]<=window_center+{30'd0,radius};
       end
       if(window_h==MAX_HARMONICS)state<=BAND_CFG;
       else begin window_h<=window_h+1'b1;window_center<=window_center+m_fund_bin;end
     end
     BAND_CFG:if(band_c_ready)begin
       read_issued<=0;read_sent<=0;read_valid<=0;state<=REPLAY;
     end
     REPLAY:begin
       if(!read_valid ||band_s_ready)begin
         read_valid<=read_issued<half_length;
         if(read_issued<half_length)read_issued<=read_issued+1'b1;
       end
       if(read_valid &&band_s_ready)begin
         read_sent<=read_sent+1'b1;
         if(read_sent==half_length-1'b1)begin read_valid<=0;state<=BANDS;end
       end
     end
     BANDS:if(band_valid)begin
       if(band_status!=0 ||band_index>=MAX_HARMONICS ||band_tag!=m_tag ||
           band_last!=(band_index==MAX_HARMONICS-1))begin
         fail(3'd6);
       end else begin
         m_components[SUM_W*band_index+:SUM_W]<=band_energy;
         if(band_index==0)m_fund<=band_energy;
         else if(band_index<harmonics)m_harm<=m_harm+band_energy;
         if(band_last)state<=RESIDUAL;
       end
     end
     RESIDUAL:begin
       if(m_fund==0 ||partition_sum>m_total)begin
         fail(3'd6);
       end else begin m_residual<=m_total-partition_sum;division<=0;state<=DIV_SEND;end
     end
     DIV_SEND:begin
       if(div_b==0)begin
         if(division==2)state<=OUTPUT;
         else division<=division+1'b1;
       end else if(div_ready)state<=DIV_WAIT;
     end
     DIV_WAIT:if(div_valid)begin
       if(div_flags!=0)begin
         fail(3'd6);
       end else begin
         m_ratio_valid[division]<=1;
         case(division)
           0:m_thd2_q16<=div_data;
           1:m_snr_q16<=div_data;
           2:m_sinad_q16<=div_data;
         endcase
         if(division==2)state<=OUTPUT;
         else begin division<=division+1'b1;state<=DIV_SEND;end
       end
     end
     OUTPUT:if(m_ready)state<=IDLE;
     default:state<=IDLE;
   endcase
 end
 generate if(MAX_LOG2N<4 ||MAX_LOG2N>12 ||MAX_HARMONICS<2 ||MAX_HARMONICS>8 ||TAG_W<1 ||TAG_W>32)begin:bad_parameters
   spectral_harmonic_quality_invalid_parameters__see_README bad();
 end endgenerate
endmodule
