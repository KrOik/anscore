// SPDX-License-Identifier: Apache-2.0
// Original discrete equal-tail power-bandwidth instrument. See README.md.
module occupied_spectral_bandwidth #(
 parameter integer MAX_BINS=1024, DATA_W=32, TAG_W=8,
 localparam integer INDEX_W=(MAX_BINS>1)?$clog2(MAX_BINS):1,
 localparam integer COUNT_W=$clog2(MAX_BINS+1),
 localparam integer SUM_W=DATA_W+((MAX_BINS>1)?$clog2(MAX_BINS):0)
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire[31:0]c_bins,
 input wire[15:0]c_occupied_num,c_occupied_den,input wire[TAG_W-1:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[DATA_W-1:0]s_power,
 output wire m_valid,input wire m_ready,output reg[1:0]m_status,
 output reg[31:0]m_low,m_high,m_span,
 output wire[SUM_W-1:0]m_total,
 output reg[SUM_W-1:0]m_retained,m_below,m_above,
 output wire[TAG_W-1:0]m_tag
);
 localparam integer PROD_W=SUM_W+17;
 localparam[3:0]IDLE=0,LOAD=1,TARGET_LOW=2,TARGET_HIGH=3,TARGET_SAVE=4,
   READ=5,PREFIX=6,CHECK=7,OUTPUT=8;
 reg[3:0]state;
 reg[DATA_W-1:0]power_ram[0:MAX_BINS-1];
 reg[DATA_W-1:0]read_power;
 reg[INDEX_W-1:0]write_index,read_index;
 reg[COUNT_W-1:0]length;
 reg[15:0]occupied_num,occupied_den;
 reg[TAG_W-1:0]tag;
 reg[SUM_W-1:0]total,prefix,prefix_before,below;
 reg[INDEX_W-1:0]low_index;
 reg low_found;
 reg[PROD_W-1:0]product,low_target,high_target;
 wire[SUM_W-1:0]load_sum=total+{{(SUM_W-DATA_W){1'b0}},s_power};
 wire[SUM_W-1:0]next_prefix=prefix+{{(SUM_W-DATA_W){1'b0}},read_power};
 // One shared registered multiplier: two frame thresholds, then one CDF/bin.
 wire[SUM_W-1:0]multiply_a=(state==TARGET_LOW ||state==TARGET_HIGH)?total:next_prefix;
 wire[16:0]multiply_b=(state==TARGET_LOW)?({1'b0,occupied_den}-{1'b0,occupied_num}):
   (state==TARGET_HIGH)?({1'b0,occupied_den}+{1'b0,occupied_num}):{occupied_den,1'b0};
 wire[PROD_W-1:0]multiply_result=multiply_a*multiply_b;
 wire[INDEX_W-1:0]selected_low=low_found?low_index:read_index;
 wire[SUM_W-1:0]selected_below=low_found?below:prefix_before;
 assign c_ready=!rst &&state==IDLE;
 assign s_ready=!rst &&state==LOAD;
 assign m_valid=!rst &&state==OUTPUT;
 assign m_total=total;assign m_tag=tag;

 always @(posedge clk)begin
   if(rst)begin
     state<=IDLE;write_index<=0;read_index<=0;length<=0;
     occupied_num<=0;occupied_den<=1;tag<=0;total<=0;prefix<=0;prefix_before<=0;
     below<=0;low_index<=0;low_found<=0;read_power<=0;product<=0;low_target<=0;high_target<=0;
     m_status<=0;m_low<=0;m_high<=0;m_span<=0;m_retained<=0;m_below<=0;m_above<=0;
   end else case(state)
     IDLE:if(c_valid)begin
       tag<=c_tag;occupied_num<=c_occupied_num;occupied_den<=c_occupied_den;
       length<=c_bins[COUNT_W-1:0];write_index<=0;read_index<=0;total<=0;
       prefix<=0;prefix_before<=0;below<=0;low_index<=0;low_found<=0;
       m_status<=0;m_low<=0;m_high<=0;m_span<=0;m_retained<=0;m_below<=0;m_above<=0;
       if(c_bins==0 ||c_bins>MAX_BINS)begin m_status<=1;state<=OUTPUT;end
       else if(c_occupied_den==0 ||c_occupied_num==0 ||c_occupied_num>c_occupied_den)begin
         m_status<=2;state<=OUTPUT;
       end else state<=LOAD;
     end
     LOAD:if(s_valid)begin
       power_ram[write_index]<=s_power;total<=load_sum;
       if(write_index==length-1'b1)begin
         if(load_sum==0)begin m_status<=3;state<=OUTPUT;end
         else state<=TARGET_LOW;
       end else write_index<=write_index+1'b1;
     end
     TARGET_LOW:begin product<=multiply_result;state<=TARGET_HIGH;end
     TARGET_HIGH:begin low_target<=product;product<=multiply_result;state<=TARGET_SAVE;end
     TARGET_SAVE:begin high_target<=product;state<=READ;end
     // Capture completes before reading; no read/write collision or RAM reset.
     READ:begin read_power<=power_ram[read_index];state<=PREFIX;end
     PREFIX:begin
       prefix_before<=prefix;prefix<=next_prefix;product<=multiply_result;state<=CHECK;
     end
     CHECK:begin
       // Low is strict; high is inclusive. At 100%, leading/trailing zeros drop.
       if(!low_found &&product>low_target)begin
         low_found<=1;low_index<=read_index;below<=prefix_before;
       end
       if(product>=high_target)begin
         m_low<=selected_low;m_high<=read_index;
         m_span<=32'(read_index)-32'(selected_low)+32'd1;
         m_below<=selected_below;m_retained<=prefix-selected_below;m_above<=total-prefix;
         state<=OUTPUT;
       end else begin read_index<=read_index+1'b1;state<=READ;end
     end
     OUTPUT:if(m_ready)state<=IDLE;
     default:state<=IDLE;
   endcase
 end
 generate if(MAX_BINS<1 ||MAX_BINS>4096 ||DATA_W<1 ||DATA_W>32 ||TAG_W<1 ||TAG_W>32)begin:bad_parameters
   occupied_spectral_bandwidth_invalid_parameters__see_README invalid();
 end endgenerate
endmodule
