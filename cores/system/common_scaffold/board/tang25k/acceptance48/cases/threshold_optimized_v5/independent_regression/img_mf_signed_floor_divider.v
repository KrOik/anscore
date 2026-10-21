// Serial signed mathematical floor with explicit bounded arithmetic stages.
// MSB shift registers remove variable-index read/write multiplexers. Each
// restoring step uses low-half subtract, high-half borrow propagation, commit.
// MIN/-1 retains the previous W-bit wrap contract; denominator0 is error01.
module img_mf_signed_floor_divider #(parameter W=36)(
    input wire clk,rst_n,clk_en,
    input wire start_valid,output wire start_ready,
    input wire signed [W-1:0] numerator,denominator,
    output reg result_valid,input wire result_ready,
    output reg signed [W-1:0] result,output reg [7:0] error
);
    localparam L=(W+1)/2,H=W-L,RH=W+1-L,CW=$clog2(W+1);
    localparam IDLE=0,ABS_LOW=1,ABS_HIGH=2,SHIFT=3,SUB_LOW=4,SUB_HIGH=5,
        COMMIT=6,SIGN_PREP=7,SIGN_LOW=8,SIGN_HIGH=9;
    reg [3:0] state;
    reg [W-1:0] numerator_q,denominator_q;
    reg numerator_negative,denominator_negative,result_negative;
    reg ncarry,dcarry,restore_carry;
    reg [W-1:0] div_dividend,div_divisor,div_quotient,div_remainder;
    reg [W:0] shifted_q;
    reg [L-1:0] difference_low;
    reg [RH-1:0] difference_high;
    reg borrow_low,subtract_ok;
    reg [L-1:0] restored_low;
    reg restored_high_carry;
    reg [CW-1:0] bits_left;
    wire [L:0] negative_n_low={1'b0,~numerator_q[L-1:0]}+1'b1;
    wire [L:0] negative_d_low={1'b0,~denominator_q[L-1:0]}+1'b1;
    wire [H:0] negative_n_high={1'b0,~numerator_q[W-1:L]}+ncarry;
    wire [H:0] negative_d_high={1'b0,~denominator_q[W-1:L]}+dcarry;
    wire [L:0] subtraction_low={1'b0,shifted_q[L-1:0]}-{1'b0,div_divisor[L-1:0]};
    wire [RH:0] subtraction_high={1'b0,shifted_q[W:L]}-{2'b0,div_divisor[W-1:L]}-borrow_low;
    wire [W:0] subtracted_remainder={difference_high,difference_low};
    wire [L-1:0] signed_low=result_negative?~div_quotient[L-1:0]:div_quotient[L-1:0];
    wire [H-1:0] signed_high=result_negative?~div_quotient[W-1:L]:div_quotient[W-1:L];
    wire [L:0] restored_low_sum={1'b0,signed_low}+restore_carry;
    wire [H:0] restored_high_sum={1'b0,signed_high}+restored_high_carry;
    assign start_ready=rst_n&&clk_en&&state==IDLE&&!result_valid;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;result_valid<=0;result<=0;error<=0;
            numerator_q<=0;denominator_q<=0;numerator_negative<=0;denominator_negative<=0;result_negative<=0;
            ncarry<=0;dcarry<=0;restore_carry<=0;
            div_dividend<=0;div_divisor<=0;div_quotient<=0;div_remainder<=0;shifted_q<=0;
            difference_low<=0;difference_high<=0;borrow_low<=0;subtract_ok<=0;
            restored_low<=0;restored_high_carry<=0;bits_left<=0;
        end else if(clk_en)begin
            if(result_valid&&result_ready)result_valid<=0;
            case(state)
                IDLE:if(start_valid&&start_ready)begin
                    error<=0;
                    if(denominator==0)begin error<=1;result<=0;result_valid<=1;end
                    else begin
                        numerator_q<=numerator;denominator_q<=denominator;
                        numerator_negative<=numerator[W-1];denominator_negative<=denominator[W-1];
                        result_negative<=numerator[W-1]^denominator[W-1];state<=ABS_LOW;
                    end
                end
                ABS_LOW:begin
                    div_dividend[L-1:0]<=numerator_negative?negative_n_low[L-1:0]:numerator_q[L-1:0];
                    div_divisor[L-1:0]<=denominator_negative?negative_d_low[L-1:0]:denominator_q[L-1:0];
                    ncarry<=negative_n_low[L];dcarry<=negative_d_low[L];state<=ABS_HIGH;
                end
                ABS_HIGH:begin
                    div_dividend[W-1:L]<=numerator_negative?negative_n_high[H-1:0]:numerator_q[W-1:L];
                    div_divisor[W-1:L]<=denominator_negative?negative_d_high[H-1:0]:denominator_q[W-1:L];
                    div_quotient<=0;div_remainder<=0;bits_left<=W;state<=SHIFT;
                end
                SHIFT:begin
                    shifted_q<={div_remainder,div_dividend[W-1]};
                    div_dividend<={div_dividend[W-2:0],1'b0};state<=SUB_LOW;
                end
                SUB_LOW:begin difference_low<=subtraction_low[L-1:0];borrow_low<=subtraction_low[L];state<=SUB_HIGH;end
                SUB_HIGH:begin difference_high<=subtraction_high[RH-1:0];subtract_ok<=!subtraction_high[RH];state<=COMMIT;end
                COMMIT:begin
                    div_remainder<=subtract_ok?subtracted_remainder[W-1:0]:shifted_q[W-1:0];
                    div_quotient<={div_quotient[W-2:0],subtract_ok};
                    if(bits_left==1)state<=SIGN_PREP;
                    else begin bits_left<=bits_left-1'b1;state<=SHIFT;end
                end
                SIGN_PREP:begin
                    // Negative nonintegral floor=-q-1=~q, while exact=-q=~q+1.
                    restore_carry<=result_negative&&(div_remainder==0);state<=SIGN_LOW;
                end
                SIGN_LOW:begin restored_low<=restored_low_sum[L-1:0];restored_high_carry<=restored_low_sum[L];state<=SIGN_HIGH;end
                SIGN_HIGH:begin result<={restored_high_sum[H-1:0],restored_low};result_valid<=1;state<=IDLE;end
                default:begin state<=IDLE;result_valid<=1;result<=0;error<=8'h80;end
            endcase
        end
    end
endmodule
