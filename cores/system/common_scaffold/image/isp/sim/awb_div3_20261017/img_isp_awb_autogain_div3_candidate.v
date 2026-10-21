// ISOLATED CANDIDATE: v95 target /3 replacement only; not board-qualified.
`timescale 1ns/1ps
// Gray-world automatic gain solver. No host gain computation is required.
// The multi-byte arithmetic is intentionally time-multiplexed to bound the
// combinational cone while retaining exact unsigned floor semantics.
module img_isp_awb_autogain_div3_candidate #(parameter SUM_WIDTH=48)(
    input wire clk,rst_n,clk_en,
    input wire stats_valid,
    output wire stats_ready,
    input wire [SUM_WIDTH-1:0] stats_sum_r,stats_sum_g,stats_sum_b,
    input wire [31:0] stats_pixel_count,stats_frame_id,
    input wire stats_overflow,
    input wire [15:0] cfg_min_gain,cfg_max_gain,
    output reg gain_valid,
    input wire gain_ready,
    output reg [15:0] gain_r,gain_g,gain_b,
    output reg [31:0] gain_frame_id,
    output reg [7:0] gain_error
);
localparam TOTAL_WIDTH=SUM_WIDTH+2;
localparam NUM_W=SUM_WIDTH+10;
localparam SUM_BYTES=(SUM_WIDTH+7)/8;
localparam SUM_PAD_WIDTH=SUM_BYTES*8;
localparam TOTAL_PAD_WIDTH=SUM_PAD_WIDTH+2;
localparam IDLE=0,SUM_TOTAL=1,DIV_TARGET=2,PREPARE=3,DIVIDE=4;
reg [2:0] state;
reg [1:0] channel;
reg [SUM_WIDTH-1:0] sums[0:2];
reg [TOTAL_PAD_WIDTH-1:0] total_padded;
wire [TOTAL_WIDTH-1:0] total_q=total_padded[TOTAL_WIDTH-1:0];
reg [TOTAL_WIDTH-1:0] target;
reg [15:0] minimum,maximum;
reg [1:0] sum_carry;
localparam SUM_INDEX_WIDTH=(SUM_BYTES<=1)?1:$clog2(SUM_BYTES);
reg [SUM_INDEX_WIDTH-1:0] sum_byte_index;
wire [SUM_PAD_WIDTH-1:0] sum_r_padded={{(SUM_PAD_WIDTH-SUM_WIDTH){1'b0}},sums[0]};
wire [SUM_PAD_WIDTH-1:0] sum_g_padded={{(SUM_PAD_WIDTH-SUM_WIDTH){1'b0}},sums[1]};
wire [SUM_PAD_WIDTH-1:0] sum_b_padded={{(SUM_PAD_WIDTH-SUM_WIDTH){1'b0}},sums[2]};
wire [9:0] sum_chunk =
    {2'b0,sum_r_padded[sum_byte_index*8 +: 8]} +
    {2'b0,sum_g_padded[sum_byte_index*8 +: 8]} +
    {2'b0,sum_b_padded[sum_byte_index*8 +: 8]} +
    {8'b0,sum_carry};

wire divider_busy,divider_done,divider_zero;
wire [NUM_W-1:0] divider_quotient;
wire [TOTAL_WIDTH-1:0] divider_remainder;
// Only channel divisions use the unchanged v95 variable divider.
wire [NUM_W-1:0] divider_numerator={target,8'b0};
wire [TOTAL_WIDTH-1:0] divider_denominator={{2{1'b0}},sums[channel]};
wire divider_start=clk_en && state==DIVIDE && !divider_busy && !divider_done;
wire target_busy,target_valid,target_start_ready;
wire [TOTAL_WIDTH-1:0] target_quotient;
wire [1:0] target_remainder;
wire target_start=clk_en && state==DIV_TARGET && !target_busy && !target_valid;
awb_constant_div3_radix4 #(.WIDTH(TOTAL_WIDTH)) u_target_div3 (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .start(target_start),.start_ready(target_start_ready),.numerator_in(total_q),
    .busy(target_busy),.result_valid(target_valid),.result_ready(state==DIV_TARGET),
    .quotient_out(target_quotient),.remainder_out(target_remainder)
);
wire [15:0] quotient_u16=divider_quotient;
wire [15:0] bounded_gain = divider_quotient>maximum ? maximum :
    (divider_quotient<minimum ? minimum : quotient_u16);

assign stats_ready=rst_n && clk_en && state==IDLE && !gain_valid;

awb_div3_candidate_byte_divider #(
    .NUM_WIDTH(NUM_W),.DEN_WIDTH(TOTAL_WIDTH)
) u_divider (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .start(divider_start),.numerator_in(divider_numerator),
    .denominator_in(divider_denominator),.busy(divider_busy),.done(divider_done),
    .quotient_out(divider_quotient),.remainder_out(divider_remainder),
    .divide_by_zero(divider_zero)
);

// Inputs are zero-padded to byte lanes, so byte-aligned and partial-byte
// SUM_WIDTH values share the same exact unsigned accumulation. Each cycle
// adds three byte lanes plus a two-bit carry and registers the carry before
// moving to the next byte. This removes the original wide sum.
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;channel<=0;target<=0;total_padded<=0;minimum<=0;maximum<=0;
        sums[0]<=0;sums[1]<=0;sums[2]<=0;
        sum_carry<=0;sum_byte_index<=0;
        gain_valid<=0;gain_r<=256;gain_g<=256;gain_b<=256;
        gain_frame_id<=0;gain_error<=0;
    end else if(clk_en) begin
        if(gain_valid && gain_ready) gain_valid<=0;
        case(state)
          IDLE: if(stats_valid && stats_ready) begin
              sums[0]<=stats_sum_r;sums[1]<=stats_sum_g;sums[2]<=stats_sum_b;
              total_padded<=0;sum_carry<=0;sum_byte_index<=0;
              minimum<=cfg_min_gain;maximum<=cfg_max_gain;
              gain_frame_id<=stats_frame_id;gain_error<=0;
              gain_r<=256;gain_g<=256;gain_b<=256;channel<=0;
              if(stats_pixel_count==0 || stats_overflow || cfg_min_gain>cfg_max_gain) begin
                  gain_error<={5'b0,cfg_min_gain>cfg_max_gain,stats_overflow,stats_pixel_count==0};
                  gain_valid<=1;
              end else state<=SUM_TOTAL;
          end
          SUM_TOTAL: begin
              total_padded[sum_byte_index*8 +: 8]<=sum_chunk[7:0];
              sum_carry<=sum_chunk[9:8];
              if(sum_byte_index==SUM_BYTES-1) begin
                  total_padded[SUM_PAD_WIDTH+1:SUM_PAD_WIDTH]<=sum_chunk[9:8];
                  state<=DIV_TARGET;
              end else sum_byte_index<=sum_byte_index+1;
          end
          DIV_TARGET: if(target_valid) begin
              // The constant denominator is 3, so no divide-by-zero path exists.
              if(total_q==0) begin
                  // A completely black frame is valid: preserve neutral gains.
                  gain_valid<=1;state<=IDLE;
              end else begin
                  target<=target_quotient;
                  state<=PREPARE;
              end
          end
          PREPARE: begin
              if(sums[channel]==0) begin
                  // Degenerate nonblack channel: use the configured gain cap.
                  gain_error[3]<=1;
                  case(channel) 0:gain_r<=maximum;1:gain_g<=maximum;2:gain_b<=maximum;endcase
                  if(channel==2) begin gain_valid<=1;state<=IDLE;end
                  else channel<=channel+1'b1;
              end else state<=DIVIDE;
          end
          DIVIDE: if(divider_done) begin
              if(divider_zero) begin
                  gain_error[7]<=1;
                  case(channel) 0:gain_r<=maximum;1:gain_g<=maximum;2:gain_b<=maximum;endcase
              end else begin
                  case(channel) 0:gain_r<=bounded_gain;1:gain_g<=bounded_gain;2:gain_b<=bounded_gain;endcase
              end
              if(channel==2) begin gain_valid<=1;state<=IDLE;end
              else begin channel<=channel+1'b1;state<=PREPARE;end
          end
          default: begin state<=IDLE;gain_valid<=1;gain_error<=8'h80;end
        endcase
    end
end
endmodule

// Unsigned restoring divider with two cascaded 8-bit borrow slices per clock.
// The number of active 16-bit groups follows the channel divisor's highest
// set bit. This unchanged variable divider handles channel gain quotients;
// the target mean uses the separate constant-three helper above.
module awb_div3_candidate_byte_divider #(
    parameter NUM_WIDTH=58,
    parameter DEN_WIDTH=50
)(
    input wire clk,rst_n,clk_en,
    input wire start,
    input wire [NUM_WIDTH-1:0] numerator_in,
    input wire [DEN_WIDTH-1:0] denominator_in,
    output reg busy,
    output reg done,
    output reg [NUM_WIDTH-1:0] quotient_out,
    output reg [DEN_WIDTH-1:0] remainder_out,
    output reg divide_by_zero
);
localparam WORK_WIDTH=((DEN_WIDTH+16)/16)*16;
localparam WORK_GROUPS=WORK_WIDTH/16;
localparam WAIT_START=0,SUBTRACT=1;
reg state;
reg [NUM_WIDTH-1:0] numerator_q,quotient_q;
reg [WORK_WIDTH-1:0] denominator_q;
reg [WORK_WIDTH-1:0] trial_q,remainder_q,candidate_q;
localparam BIT_INDEX_WIDTH=(NUM_WIDTH<=1)?1:$clog2(NUM_WIDTH);
localparam GROUP_INDEX_WIDTH=(WORK_GROUPS<=1)?1:$clog2(WORK_GROUPS);
localparam GROUP_COUNT_WIDTH=(WORK_GROUPS<=1)?1:$clog2(WORK_GROUPS+1);
reg [BIT_INDEX_WIDTH-1:0] bit_index;
reg [GROUP_INDEX_WIDTH-1:0] group_index;
reg [GROUP_COUNT_WIDTH-1:0] active_groups;
wire [GROUP_COUNT_WIDTH-1:0] group_ordinal={1'b0,group_index}+1'b1;
wire [BIT_INDEX_WIDTH-1:0] next_bit_index=bit_index-1'b1;
reg borrow_q;

// The trial remainder needs one bit more than the divisor. Group the
// left-shifted divisor directly, instead of a 32-bit highest-bit arithmetic
// encoder; the returned count is always 1..WORK_GROUPS (including zero).
function [GROUP_COUNT_WIDTH-1:0] divisor_groups;
    input [DEN_WIDTH-1:0] value;
    reg [WORK_WIDTH-1:0] shifted_value;
    integer i;
    begin
        shifted_value={value,1'b0};
        divisor_groups=1;
        for(i=0;i<WORK_GROUPS;i=i+1)
            if(|shifted_value[i*16 +:16]) divisor_groups=i+1;
    end
endfunction

wire [15:0] group_difference;
wire borrow8,borrow16;
awb_div3_candidate_sub_prefix16 subtract_group(
    .a(trial_q[group_index*16 +: 16]),
    .b(denominator_q[group_index*16 +: 16]),.borrow_in(borrow_q),
    .difference(group_difference),.borrow8(borrow8),.borrow16(borrow16));
wire [8:0] diff_lo={borrow8,group_difference[7:0]};
wire [8:0] diff_hi={borrow16,group_difference[15:8]};
reg [WORK_WIDTH-1:0] candidate_next;
integer gi;
always @* begin
    candidate_next=candidate_q;
    for(gi=0;gi<WORK_GROUPS;gi=gi+1) begin
        if(group_index==gi)
            candidate_next[gi*16 +: 16]={diff_hi[7:0],diff_lo[7:0]};
    end
end
wire [WORK_WIDTH-1:0] remainder_next = diff_hi[8] ? trial_q : candidate_next;
wire [NUM_WIDTH-1:0] quotient_next={quotient_q[NUM_WIDTH-2:0],~diff_hi[8]};

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=WAIT_START;busy<=0;done<=0;quotient_out<=0;remainder_out<=0;
        divide_by_zero<=0;numerator_q<=0;quotient_q<=0;denominator_q<=0;
        trial_q<=0;remainder_q<=0;candidate_q<=0;
        bit_index<=0;group_index<=0;active_groups<=1;borrow_q<=0;
    end else if(clk_en) begin
        done<=0;
        case(state)
          WAIT_START: if(start) begin
              numerator_q<=numerator_in;
              denominator_q<={{(WORK_WIDTH-DEN_WIDTH){1'b0}},denominator_in};
              quotient_q<=0;quotient_out<=0;remainder_q<=0;remainder_out<=0;
              divide_by_zero<=0;
              if(denominator_in==0) begin
                  busy<=0;done<=1;divide_by_zero<=1;
              end else begin
                  active_groups<=divisor_groups(denominator_in);
                  bit_index<=NUM_WIDTH-1;group_index<=0;borrow_q<=0;
                  candidate_q<=0;
                  trial_q<={{(WORK_WIDTH-1){1'b0}},numerator_in[NUM_WIDTH-1]};
                  busy<=1;state<=SUBTRACT;
              end
          end
          SUBTRACT: begin
              candidate_q<=candidate_next;
              borrow_q<=diff_hi[8];
              if(group_ordinal==active_groups) begin
                  remainder_q<=remainder_next;
                  quotient_q<=quotient_next;
                  borrow_q<=0;candidate_q<=0;group_index<=0;
                  if(bit_index==0) begin
                      quotient_out<=quotient_next;
                      remainder_out<=remainder_next[DEN_WIDTH-1:0];
                      busy<=0;done<=1;state<=WAIT_START;
                  end else begin
                      bit_index<=next_bit_index;
                      trial_q<={remainder_next[WORK_WIDTH-2:0],numerator_q[next_bit_index]};
                  end
              end else group_index<=group_index+1'b1;
          end
          default: begin state<=WAIT_START;busy<=0;done<=1;divide_by_zero<=1;end
        endcase
    end
end
endmodule


// Exact 16-bit subtract with input borrow and retained four-nibble prefixes.
// A borrow propagates through a nibble precisely when its operands are equal.
module awb_div3_candidate_sub_prefix16(
    input wire [15:0] a,b,
    input wire borrow_in,
    output wire [15:0] difference,
    output wire borrow8,borrow16
);
    (* keep=1 *) wire [3:0] group_p[0:2];
    (* keep=1 *) wire [3:0] group_g[0:2];
    wire [4:0] borrow;
    assign borrow[0]=borrow_in;
    assign borrow8=borrow[2];
    assign borrow16=borrow[4];
    genvar n,lev;
    generate for(n=0;n<4;n=n+1) begin: nibble
        wire [3:0] av=a[n*4+:4],bv=b[n*4+:4];
        wire [4:0] local_difference={1'b0,av}-{1'b0,bv};
        assign group_p[0][n]=(av==bv);
        assign group_g[0][n]=local_difference[4];
        assign borrow[n+1]=group_g[2][n] | (group_p[2][n]&borrow_in);
        assign difference[n*4+:4]=av-bv-borrow[n];
    end
    for(lev=0;lev<2;lev=lev+1) begin: level
        for(n=0;n<4;n=n+1) begin: node
            if(n >= (1<<lev)) begin: combine
                assign group_g[lev+1][n]=group_g[lev][n] |
                    (group_p[lev][n]&group_g[lev][n-(1<<lev)]);
                assign group_p[lev+1][n]=group_p[lev][n]&group_p[lev][n-(1<<lev)];
            end else begin: pass
                assign group_g[lev+1][n]=group_g[lev][n];
                assign group_p[lev+1][n]=group_p[lev][n];
            end
        end
    end endgenerate
endmodule
