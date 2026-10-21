// Candidate: exact production bilateral arithmetic with a shared iterative
// divider for spatial weight, range weight and final normalization. Latency
// increases; cfg Q8.8, Q0.16 exp LUT, rounding and stream values are unchanged.
module img_filter_bilateral3x3 #(parameter PIXEL_W=8)(
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,input wire [7:0] cmd_tag,
    input wire [15:0] cfg_sigma_spatial_q8,cfg_sigma_range_q8,
    output wire rsp_valid,input wire rsp_ready,output wire [7:0] rsp_tag,rsp_error,
    input wire [9*PIXEL_W-1:0] s_taps,input wire s_valid,s_sof,s_eol,
    output wire s_ready,output wire [PIXEL_W-1:0] m_data,
    output wire m_valid,m_sof,m_eol,input wire m_ready
);
    localparam NUM_W=PIXEL_W+20;
    localparam RANGE_W=2*PIXEL_W+19;
    localparam DIV_W=(RANGE_W>32)?RANGE_W:32;
    localparam [4:0] IDLE=0,SP_PREP=1,SP_START=2,SP_WAIT=3,
        RN_PREP=4,RN_START=5,RN_WAIT=6,ACCUM=7,
        NM_PREP=8,NM_START=9,NM_WAIT=10,OUTPUT_HOLD=11,
        SAMPLE_REG=12,WEIGHT_PRODUCT=13,CFG_PART=14,CFG_LOW=15,CFG_HIGH=16,WEIGHT_CAPTURE=17,PRODUCT_WAIT=18,ADD_FOLD=19;
    localparam PAD_W=((NUM_W+7)/8)*8,ADD_BYTES=PAD_W/8;
    reg [PAD_W-1:0] add_a,add_b,den_a,den_b,add_result,den_result;
    reg add_carry,den_carry,normalizing;
    reg [$clog2(ADD_BYTES+1)-1:0] add_count;
    wire [8:0] byte_sum={1'b0,add_a[7:0]}+{1'b0,add_b[7:0]}+add_carry;
    wire [8:0] den_sum={1'b0,den_a[7:0]}+{1'b0,den_b[7:0]}+den_carry;
    wire [PAD_W-1:0] add_next={byte_sum[7:0],add_result[PAD_W-1:8]};
    wire [PAD_W-1:0] den_next={den_sum[7:0],den_result[PAD_W-1:8]};
    reg [4:0] state;
    reg configured,response_valid,output_valid,output_sof,output_eol;
    reg [7:0] tag,error_code,weight_index;
    reg [15:0] sigma_s,sigma_r;
    reg [15:0] ss_ll_q,ss_lh_q,ss_hh_q,sr_ll_q,sr_lh_q,sr_hh_q;
    reg [24:0] ss_low_q,sr_low_q;
    reg [31:0] spatial_square,range_square;
    reg [9*PIXEL_W-1:0] window;
    reg [PIXEL_W-1:0] result,sample_q,delta_q;
    reg [1:0] distance_q;
    reg [NUM_W-1:0] product_q;
    reg saved_sof,saved_eol;
    reg [3:0] tap;
    reg [NUM_W-1:0] numerator;
    reg [19:0] denominator;
    reg [DIV_W-1:0] dividend,spatial_index;
    reg [31:0] divisor;
    wire [DIV_W-1:0] quotient;
    wire divide_busy,divide_done;
    wire divide_start=state==SP_START||state==RN_START||state==NM_START;
    wire [PIXEL_W-1:0] sample=window[tap*PIXEL_W+:PIXEL_W];
    wire [PIXEL_W-1:0] center=window[4*PIXEL_W+:PIXEL_W];
    wire [PIXEL_W-1:0] delta=sample>=center?sample-center:center-sample;
    wire [2*PIXEL_W-1:0] delta_squared=delta_q*delta_q;
    wire [1:0] distance=(tap==4)?0:((tap==0||tap==2||tap==6||tap==8)?2:1);
    wire [20:0] spatial_numerator={distance_q,19'd0};
    wire [RANGE_W-1:0] range_numerator={delta_squared,19'd0};
    wire [8:0] index_sum={1'b0,spatial_index[7:0]}+{1'b0,quotient[7:0]};
    wire index_high=(|spatial_index[DIV_W-1:8]) || (|quotient[DIV_W-1:8]);
    wire [15:0] weight;
    reg [15:0] weight_q;
    wire product_ready,product_valid;
    wire [PIXEL_W+15:0] weighted_sample;
    cip_bilateral_unsigned_multiply #(.A_W(PIXEL_W),.B_W(16)) weight_multiplier(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .s_valid(state==WEIGHT_PRODUCT),.s_ready(product_ready),.s_a(sample_q),.s_b(weight_q),
        .m_valid(product_valid),.m_ready(state==PRODUCT_WAIT),.m_product(weighted_sample));
    wire [NUM_W-1:0] rounded_numerator=numerator+(denominator>>1);
    img_filter_exp_weight exp_lut(.index(weight_index),.weight(weight));
    img_bilateral_unsigned_divider #(.WIDTH(DIV_W)) divider(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.start(divide_start),
        .dividend(dividend),.divisor(divisor),.busy(divide_busy),
        .done(divide_done),.quotient(quotient));
    assign cmd_ready=rst_n&&clk_en&&state==IDLE&&!output_valid&&(!response_valid||rsp_ready);
    assign rsp_valid=response_valid;assign rsp_tag=tag;assign rsp_error=error_code;
    assign s_ready=rst_n&&clk_en&&configured&&state==IDLE&&!output_valid&&!cmd_valid;
    assign m_data=result;assign m_valid=output_valid;assign m_sof=output_sof;assign m_eol=output_eol;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            add_a<=0;add_b<=0;den_a<=0;den_b<=0;add_result<=0;den_result<=0;add_carry<=0;den_carry<=0;normalizing<=0;add_count<=0;
            state<=IDLE;configured<=0;response_valid<=0;output_valid<=0;
            output_sof<=0;output_eol<=0;tag<=0;error_code<=0;weight_index<=0;
            sigma_s<=0;sigma_r<=0;
            ss_ll_q<=0;ss_lh_q<=0;ss_hh_q<=0;sr_ll_q<=0;sr_lh_q<=0;sr_hh_q<=0;
            ss_low_q<=0;sr_low_q<=0;spatial_square<=0;range_square<=0;window<=0;result<=0;saved_sof<=0;saved_eol<=0;
            tap<=0;numerator<=0;denominator<=0;dividend<=0;divisor<=0;spatial_index<=0;
            sample_q<=0;delta_q<=0;distance_q<=0;product_q<=0;weight_q<=0;
        end else if(clk_en)begin
            if(response_valid&&rsp_ready)response_valid<=0;
            if(output_valid&&m_ready)output_valid<=0;
            if(cmd_valid&&cmd_ready)begin
                tag<=cmd_tag;error_code<=0;response_valid<=1;
                if(cfg_sigma_spatial_q8==0||cfg_sigma_range_q8==0||PIXEL_W<1||PIXEL_W>12)begin
                    configured<=0;error_code<=1;
                end else begin configured<=1;sigma_s<=cfg_sigma_spatial_q8;sigma_r<=cfg_sigma_range_q8;state<=CFG_PART;end
            end
            case(state)
                IDLE:if(s_valid&&s_ready)begin
                    window<=s_taps;saved_sof<=s_sof;saved_eol<=s_eol;
                    numerator<=0;denominator<=0;tap<=0;state<=SAMPLE_REG;
                end
                CFG_PART:begin
                    ss_ll_q<=sigma_s[7:0]*sigma_s[7:0];ss_lh_q<=sigma_s[7:0]*sigma_s[15:8];ss_hh_q<=sigma_s[15:8]*sigma_s[15:8];
                    sr_ll_q<=sigma_r[7:0]*sigma_r[7:0];sr_lh_q<=sigma_r[7:0]*sigma_r[15:8];sr_hh_q<=sigma_r[15:8]*sigma_r[15:8];state<=CFG_LOW;
                end
                CFG_LOW:begin
                    ss_low_q<={9'd0,ss_ll_q}+{ss_lh_q,9'd0};
                    sr_low_q<={9'd0,sr_ll_q}+{sr_lh_q,9'd0};state<=CFG_HIGH;
                end
                CFG_HIGH:begin
                    spatial_square<={ss_hh_q,16'd0}+{7'd0,ss_low_q};
                    range_square<={sr_hh_q,16'd0}+{7'd0,sr_low_q};state<=IDLE;
                end
                SAMPLE_REG:begin sample_q<=sample;delta_q<=delta;distance_q<=distance;state<=SP_PREP;end
                SP_PREP:begin dividend<=spatial_numerator;divisor<=spatial_square;state<=SP_START;end
                SP_START:state<=SP_WAIT;
                SP_WAIT:if(divide_done)begin spatial_index<=quotient;state<=RN_PREP;end
                RN_PREP:begin dividend<=range_numerator;divisor<=range_square;state<=RN_START;end
                RN_START:state<=RN_WAIT;
                RN_WAIT:if(divide_done)begin weight_index<=(index_high || index_sum[8])?255:index_sum[7:0];state<=WEIGHT_CAPTURE;end
                WEIGHT_CAPTURE:begin weight_q<=weight;state<=WEIGHT_PRODUCT;end
                WEIGHT_PRODUCT:if(product_ready)state<=PRODUCT_WAIT;
                PRODUCT_WAIT:if(product_valid)begin product_q<=weighted_sample;state<=ACCUM;end
                ACCUM:begin
                    add_a<=numerator;add_b<=product_q;den_a<=denominator;den_b<=weight_q;
                    add_result<=0;den_result<=0;add_carry<=0;den_carry<=0;
                    normalizing<=0;add_count<=ADD_BYTES;state<=ADD_FOLD;
                end
                NM_PREP:begin
                    add_a<=numerator;add_b<=denominator>>1;den_a<=0;den_b<=0;
                    add_result<=0;den_result<=0;add_carry<=0;den_carry<=0;
                    normalizing<=1;add_count<=ADD_BYTES;state<=ADD_FOLD;
                end
                ADD_FOLD:begin
                    add_a<=add_a>>8;add_b<=add_b>>8;den_a<=den_a>>8;den_b<=den_b>>8;
                    add_result<=add_next;den_result<=den_next;
                    add_carry<=byte_sum[8];den_carry<=den_sum[8];add_count<=add_count-1'b1;
                    if(add_count==1)begin
                        if(normalizing)begin
                            // Preserve the original modulo-NUM_W round before divide.
                            dividend<=add_next[NUM_W-1:0];divisor<={12'd0,denominator};
                            output_sof<=saved_sof;output_eol<=saved_eol;
                            if(denominator==0)begin result<=0;output_valid<=1;state<=OUTPUT_HOLD;end
                            else state<=NM_START;
                        end else begin
                            numerator<=add_next[NUM_W-1:0];denominator<=den_next[19:0];
                            if(tap==8)state<=NM_PREP;
                            else begin tap<=tap+1'b1;state<=SAMPLE_REG;end
                        end
                    end
                end
                NM_START:state<=NM_WAIT;
                NM_WAIT:if(divide_done)begin result<=quotient[PIXEL_W-1:0];output_valid<=1;state<=OUTPUT_HOLD;end
                OUTPUT_HOLD:if(output_valid&&m_ready)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule

// Unsigned restoring divider. Each quotient bit has two CE stages, with a
// 16-bit low subtraction and 17-bit high subtraction including registered
// borrow. The 33-bit trial remainder never becomes a single carry chain.
module img_bilateral_unsigned_divider #(parameter WIDTH=35)(
    input wire clk,rst_n,clk_en,start,
    input wire [WIDTH-1:0] dividend,input wire [31:0] divisor,
    output reg busy,done,output reg [WIDTH-1:0] quotient
);
    localparam COUNT_W=$clog2(WIDTH+1);
    reg [WIDTH-1:0] dividend_q;
    reg [31:0] divisor_q,remainder;
    reg [COUNT_W-1:0] count;
    reg phase,low_borrow;
    reg [15:0] low_difference;
    reg [32:0] trial_q;
    wire [32:0] trial={remainder,dividend_q[WIDTH-1]};
    // Exact unsigned17-bit subtraction with independent byte comparisons.
    function [17:0] subtract17;
        input [16:0] a,b;
        input borrow_in;
        reg borrow8,borrow16,borrow17;
        begin
            borrow8=(a[7:0]<b[7:0]) || ((a[7:0]==b[7:0]) && borrow_in);
            borrow16=(a[15:8]<b[15:8]) || ((a[15:8]==b[15:8]) && borrow8);
            borrow17=(a[16]<b[16]) || ((a[16]==b[16]) && borrow16);
            subtract17[7:0]=a[7:0]-b[7:0]-borrow_in;
            subtract17[15:8]=a[15:8]-b[15:8]-borrow8;
            subtract17[16]=a[16]^b[16]^borrow16;
            subtract17[17]=borrow17;
        end
    endfunction
    wire [17:0] low_wide=subtract17({1'b0,trial[15:0]},{1'b0,divisor_q[15:0]},1'b0);
    wire [16:0] low_sub={low_wide[17],low_wide[15:0]};
    wire [17:0] high_sub=subtract17(trial_q[32:16],{1'b0,divisor_q[31:16]},low_borrow);
    wire take_subtract=!high_sub[17];
    wire [32:0] sub_result={high_sub[16:0],low_difference};
    wire [WIDTH-1:0] quotient_next={quotient[WIDTH-2:0],take_subtract};
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            busy<=0;done<=0;quotient<=0;dividend_q<=0;divisor_q<=0;remainder<=0;
            count<=0;phase<=0;low_borrow<=0;low_difference<=0;trial_q<=0;
        end else if(clk_en)begin
            done<=0;
            if(!busy)begin
                if(start)begin
                    quotient<=0;dividend_q<=dividend;divisor_q<=divisor;remainder<=0;
                    count<=WIDTH;phase<=0;
                    if(divisor==0)begin quotient<={WIDTH{1'b1}};done<=1;end
                    else busy<=1;
                end
            end else if(!phase)begin
                trial_q<=trial;low_difference<=low_sub[15:0];low_borrow<=low_sub[16];phase<=1;
            end else begin
                remainder<=take_subtract?sub_result[31:0]:trial_q[31:0];
                dividend_q<=dividend_q<<1;quotient<=quotient_next;phase<=0;
                if(count==1)begin busy<=0;done<=1;count<=0;end
                else count<=count-1'b1;
            end
        end
    end
endmodule

// Exact unsigned carry-save shift/add multiplier. B_W CSA iterations,
// then ceil((A_W+B_W)/8) byte-carry fold iterations. Shared CE/ready handshake.
module cip_bilateral_unsigned_multiply #(parameter A_W=64,B_W=32)(
 input wire clk,rst_n,clk_en,input wire s_valid,output wire s_ready,
 input wire [A_W-1:0] s_a,input wire [B_W-1:0] s_b,
 output reg m_valid,input wire m_ready,output reg [A_W+B_W-1:0] m_product
);
localparam W=A_W+B_W,PAD_W=((W+7)/8)*8,CHUNKS=PAD_W/8;
localparam CW=$clog2(B_W+CHUNKS+1)>0?$clog2(B_W+CHUNKS+1):1;
reg [1:0] state;
reg [PAD_W-1:0] multiplicand,sum_vector,carry_vector,fold_product;
reg [B_W-1:0] multiplier;
reg [CW-1:0] remaining;
reg fold_carry;
wire [PAD_W-1:0] addend=multiplier[0]?multiplicand:{PAD_W{1'b0}};
wire [PAD_W-1:0] csa_sum=sum_vector^carry_vector^addend;
wire [PAD_W-1:0] csa_carry=((sum_vector&carry_vector)|(sum_vector&addend)|(carry_vector&addend))<<1;
wire [8:0] fold_sum={1'b0,sum_vector[7:0]}+{1'b0,carry_vector[7:0]}+fold_carry;
wire [PAD_W-1:0] next_product=(fold_product>>8)|({{(PAD_W-8){1'b0}},fold_sum[7:0]}<<(PAD_W-8));
assign s_ready=rst_n && state==0 && !m_valid;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=0;m_valid<=0;m_product<=0;multiplicand<=0;sum_vector<=0;carry_vector<=0;fold_product<=0;multiplier<=0;remaining<=0;fold_carry<=0;end
 else if(clk_en)begin
 if(m_valid && m_ready)m_valid<=0;
 if(s_valid && s_ready)begin
 multiplicand<=s_a;multiplier<=s_b;sum_vector<=0;carry_vector<=0;remaining<=B_W;state<=1;fold_carry<=0;fold_product<=0;
 end else if(state==1)begin
 sum_vector<=csa_sum;carry_vector<=csa_carry;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
 if(remaining==1)begin remaining<=CHUNKS;state<=2;end else remaining<=remaining-1'b1;
 end else if(state==2)begin
 sum_vector<=sum_vector>>8;carry_vector<=carry_vector>>8;fold_carry<=fold_sum[8];fold_product<=next_product;
 if(remaining==1)begin m_product<=next_product[W-1:0];m_valid<=1;state<=0;end else remaining<=remaining-1'b1;
 end
 end
end
endmodule
