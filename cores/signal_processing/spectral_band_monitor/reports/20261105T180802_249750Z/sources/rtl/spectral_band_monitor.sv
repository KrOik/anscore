// SPDX-License-Identifier: Apache-2.0
// One accepted ordered power spectrum -> overlapping band measurement records.
module spectral_band_monitor #(
 parameter integer MAX_BINS=1024,BANDS=4,TAG_W=8,
 localparam integer INDEX_W=(MAX_BINS<2)?1:$clog2(MAX_BINS),
 localparam integer COUNT_W=(MAX_BINS<2)?1:$clog2(MAX_BINS+1),
 localparam integer SUM_W=32+INDEX_W,
 localparam integer MOMENT_W=32+2*INDEX_W
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [31:0] c_bins,c_threshold,
 input wire [32*BANDS-1:0] c_low,c_high,
 input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire [31:0] s_power,
 output reg m_valid,input wire m_ready,
 output reg [1:0] m_status,
 output reg [31:0] m_band,m_low,m_high,
 output reg [SUM_W-1:0] m_energy,
 output reg [MOMENT_W-1:0] m_moment,
 output reg [31:0] m_peak_power,m_peak_bin,m_above,
 output reg m_last,output reg [TAG_W-1:0]m_tag
);
 localparam integer BAND_W=(BANDS<2)?1:$clog2(BANDS);
 localparam [2:0] IDLE=0,LOAD=1,FLUSH=2,EMIT=3,HOLD=4;
 reg [2:0]state;
 reg [COUNT_W-1:0]length;
 reg [INDEX_W-1:0]input_index;
 reg [INDEX_W-1:0]lo[0:BANDS-1],hi[0:BANDS-1],peak_index[0:BANDS-1];
 reg [SUM_W-1:0]energy[0:BANDS-1];
 reg [MOMENT_W-1:0]moment[0:BANDS-1];
 reg [31:0]peak_power[0:BANDS-1];
 reg [COUNT_W-1:0]above[0:BANDS-1];
 reg [31:0]threshold;
 reg [TAG_W-1:0]tag;
 reg [BAND_W-1:0]emit_band;
 reg p_valid;
 reg [31:0]p_power;
 reg [INDEX_W-1:0]p_index;
 reg [32+INDEX_W-1:0]p_weighted;
 reg bad_band;
 reg [31:0]first_bad;
 integer b,q;
 generate if(MAX_BINS<1 || MAX_BINS>4096 || BANDS<1 || BANDS>8 || TAG_W<1 ||TAG_W>32)begin:invalid
   spectral_band_monitor_invalid_parameters__see_README bad_parameters();
 end endgenerate
 assign c_ready=!rst && state==IDLE;
 assign s_ready=!rst && state==LOAD;
 always @*begin
   bad_band=0;first_bad=0;
   for(q=0;q<BANDS;q=q+1)begin
     if(!bad_band && (c_low[32*q+:32]>c_high[32*q+:32] || c_high[32*q+:32]>=c_bins))begin
       bad_band=1;first_bad=q;
     end
   end
 end
 always @(posedge clk)begin
   if(rst)begin
     state<=IDLE;length<=0;input_index<=0;threshold<=0;tag<=0;emit_band<=0;
     p_valid<=0;p_power<=0;p_index<=0;p_weighted<=0;
     m_valid<=0;m_status<=0;m_band<=0;m_low<=0;m_high<=0;m_energy<=0;m_moment<=0;
     m_peak_power<=0;m_peak_bin<=0;m_above<=0;m_last<=0;m_tag<=0;
   end else begin
     p_valid<=0;
     // The registered common weighted product is shared by every matching band.
     if(p_valid)for(b=0;b<BANDS;b=b+1)begin
       if(p_index>=lo[b] &&p_index<=hi[b])begin
         energy[b]<=energy[b]+{{(SUM_W-32){1'b0}},p_power};
         moment[b]<=moment[b]+{{(MOMENT_W-32-INDEX_W){1'b0}},p_weighted};
         if(p_index==lo[b] ||p_power>peak_power[b])begin peak_power[b]<=p_power;peak_index[b]<=p_index;end
         if(p_power>=threshold)above[b]<=above[b]+1'b1;
       end
     end
     case(state)
       IDLE:if(c_valid &&c_ready)begin
         tag<=c_tag;threshold<=c_threshold;input_index<=0;emit_band<=0;
         if(c_bins==0 ||c_bins>MAX_BINS ||bad_band)begin
           m_valid<=1;m_status<=(c_bins==0 ||c_bins>MAX_BINS)?1:2;
           m_band<=(c_bins==0 ||c_bins>MAX_BINS)?0:first_bad;
           m_low<=0;m_high<=0;m_energy<=0;m_moment<=0;m_peak_power<=0;m_peak_bin<=0;m_above<=0;
           m_last<=1;m_tag<=c_tag;state<=HOLD;
         end else begin
           length<=c_bins[COUNT_W-1:0];
           for(b=0;b<BANDS;b=b+1)begin
             lo[b]<=c_low[32*b+:INDEX_W];hi[b]<=c_high[32*b+:INDEX_W];
             energy[b]<=0;moment[b]<=0;peak_power[b]<=0;peak_index[b]<=0;above[b]<=0;
           end
           state<=LOAD;
         end
       end
       LOAD:if(s_valid &&s_ready)begin
         p_valid<=1;p_power<=s_power;p_index<=input_index;p_weighted<=s_power*input_index;
         if(input_index==length-1'b1)state<=FLUSH;
         else input_index<=input_index+1'b1;
       end
       FLUSH:state<=EMIT;
       EMIT:begin
         m_valid<=1;m_status<=0;m_band<=emit_band;m_low<=lo[emit_band];m_high<=hi[emit_band];
         m_energy<=energy[emit_band];m_moment<=moment[emit_band];m_peak_power<=peak_power[emit_band];
         m_peak_bin<=peak_index[emit_band];m_above<=above[emit_band];m_last<=(emit_band==BANDS-1);m_tag<=tag;
         state<=HOLD;
       end
       HOLD:if(m_valid &&m_ready)begin
         m_valid<=0;
         if(m_status!=0 ||m_last)state<=IDLE;
         else begin emit_band<=emit_band+1'b1;state<=EMIT;end
       end
       default:state<=IDLE;
     endcase
   end
 end
endmodule
