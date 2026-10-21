// Bilateral 3x3 kernel: exp(-distance^2/(2*sigma_s^2)-delta^2/(2*sigma_r^2)).
// Exponential is quantized to steps of 1/16 with 16-bit weights.
// cfg_sigma_spatial_q8 and cfg_sigma_range_q8 are unsigned Q8.8 declarations.
// Commands configure/acknowledge sigma; subsequent windows are processed until reconfiguration.
module img_filter_bilateral3x3 #(parameter PIXEL_W = 8)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire [7:0] cmd_tag,
    input wire [15:0] cfg_sigma_spatial_q8, cfg_sigma_range_q8,
    output wire rsp_valid, input wire rsp_ready,
    output wire [7:0] rsp_tag, rsp_error,
    input wire [9*PIXEL_W-1:0] s_taps,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    reg configured,response_valid,output_valid,output_sof,output_eol;
    reg [7:0] tag,error_code;
    reg [15:0] sigma_s,sigma_r;
    reg [9*PIXEL_W-1:0] window;
    reg [PIXEL_W-1:0] result;
    reg saved_sof,saved_eol;
    reg [2:0] state;
    integer tap,dx,dy;
    // The supported 1..12-bit pixel range bounds the exact products and sums.
    // Keep divider operands at those mathematical widths instead of allowing
    // 64-bit context to turn three small quotients into 64-bit dividers.
    localparam NUM_W=PIXEL_W+20;
    localparam RANGE_NUM_W=2*PIXEL_W+19;
    localparam INDEX_W=2*PIXEL_W+20;
    reg [NUM_W-1:0] numerator;
    reg [19:0] denominator;
    reg [NUM_W-1:0] divide_dividend,divide_quotient;
    reg [20:0] divide_remainder;
    reg [5:0] divide_count;
    wire [31:0] spatial_square=sigma_s*sigma_s;
    wire [31:0] range_square=sigma_r*sigma_r;
    wire [1:0] spatial_distance=dx*dx+dy*dy;
    wire [PIXEL_W-1:0] center_sample=window[4*PIXEL_W+:PIXEL_W];
    wire [PIXEL_W-1:0] sample=window[tap*PIXEL_W+:PIXEL_W];
    // Range distance is unsigned; select the larger sample before subtracting
    // so every supported pixel width computes |sample-center| without signed
    // integer sizing or truncation rules.
    wire [PIXEL_W-1:0] abs_difference=(sample>=center_sample) ?
        sample-center_sample : center_sample-sample;
    wire [2*PIXEL_W-1:0] squared_difference=abs_difference*abs_difference;
    wire [20:0] spatial_numerator={spatial_distance,19'd0};
    wire [RANGE_NUM_W-1:0] range_numerator={squared_difference,19'd0};
    wire [31:0] spatial_index=(spatial_square==0)?0:(spatial_numerator/spatial_square);
    wire [RANGE_NUM_W-1:0] range_index=(range_square==0)?0:(range_numerator/range_square);
    wire [INDEX_W-1:0] index_wide=spatial_index+range_index;
    wire [7:0] weight_index=(index_wide>255)?255:index_wide[7:0];
    wire [15:0] weight;
    wire [NUM_W-1:0] weighted_sample=sample*weight;
    wire [NUM_W-1:0] rounded_numerator=numerator+(denominator>>1);
    wire [20:0] divide_remainder_trial={divide_remainder[19:0],divide_dividend[NUM_W-1]};
    wire [20:0] divide_denominator_ext={1'b0,denominator};
    wire divide_quotient_bit=(divide_remainder_trial>=divide_denominator_ext);
    wire [20:0] divide_remainder_next=divide_quotient_bit ?
        divide_remainder_trial-divide_denominator_ext : divide_remainder_trial;
    wire [NUM_W-1:0] divide_quotient_next={divide_quotient[NUM_W-2:0],divide_quotient_bit};
    // One 21-bit compare/subtract per cycle avoids the board-only quotient
    // mismatch observed with the previous combinational division operator.
    img_filter_exp_weight exp_lut(.index(weight_index),.weight(weight));
    assign cmd_ready=rst_n && clk_en && state==0 && !output_valid && (!response_valid || rsp_ready);
    assign rsp_valid=response_valid;assign rsp_tag=tag;assign rsp_error=error_code;
    assign s_ready=rst_n && clk_en && configured && state==0 && !output_valid && !cmd_valid;
    assign m_data=result;assign m_valid=output_valid;assign m_sof=output_sof;assign m_eol=output_eol;
    always @* begin
        dx=tap%3-1;dy=tap/3-1;
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            configured<=0;response_valid<=0;output_valid<=0;output_sof<=0;output_eol<=0;
            tag<=0;error_code<=0;sigma_s<=0;sigma_r<=0;window<=0;result<=0;
            saved_sof<=0;saved_eol<=0;state<=0;tap<=0;numerator<=0;denominator<=0;
            divide_dividend<=0;divide_quotient<=0;divide_remainder<=0;divide_count<=0;
        end else if(clk_en)begin
            if(response_valid && rsp_ready)response_valid<=0;
            if(output_valid && m_ready)output_valid<=0;
            if(cmd_valid && cmd_ready)begin
                tag<=cmd_tag;response_valid<=1;error_code<=0;
                if(cfg_sigma_spatial_q8==0 || cfg_sigma_range_q8==0 || PIXEL_W>12 || PIXEL_W<1)begin
                    configured<=0;error_code<=1;
                end else begin configured<=1;sigma_s<=cfg_sigma_spatial_q8;sigma_r<=cfg_sigma_range_q8;end
            end
            case(state)
              0:if(s_valid && s_ready)begin
                  window<=s_taps;saved_sof<=s_sof;saved_eol<=s_eol;
                  numerator<=0;denominator<=0;tap<=0;state<=1;
              end
              1:begin
                  numerator<=numerator+weighted_sample;denominator<=denominator+weight;
                  if(tap==8)state<=2;else tap<=tap+1;
              end
              2:begin
                  divide_dividend<=rounded_numerator;
                  divide_quotient<=0;divide_remainder<=0;divide_count<=NUM_W;
                  output_sof<=saved_sof;output_eol<=saved_eol;
                  if(denominator==0)begin
                      divide_count<=0;result<=0;output_valid<=1;state<=4;
                  end else state<=3;
              end
              3:begin
                  divide_dividend<=divide_dividend<<1;
                  divide_remainder<=divide_remainder_next;
                  divide_quotient<=divide_quotient_next;
                  if(divide_count==1)begin
                      divide_count<=0;result<=divide_quotient_next[PIXEL_W-1:0];
                      output_valid<=1;state<=4;
                  end else divide_count<=divide_count-1'b1;
              end
              4:begin
                  if(output_valid && m_ready)state<=0;
              end
              default:state<=0;
            endcase
        end
    end
endmodule
