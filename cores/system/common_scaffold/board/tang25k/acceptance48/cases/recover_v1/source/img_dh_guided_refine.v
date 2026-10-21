// Full-frame grayscale-guided filter; shared arithmetic implementation for
// img_dh_guided_frame. Small exact-reference group simulation covered this path.
// Stores input and a/b coefficients in synchronous-read RAM, then evaluates
// q = mean(a)*I + mean(b), a = cov(I,p)/(var(I)+epsilon), b=mean(p)-a*mean(I).
// I is 8-bit guide; p/q unsigned Q1.15. Coefficients retain 16 extra fraction
// bits relative to p. Box borders replicate edge coordinates. Three signed
// solve quotients share a byte-serial divider (656 enabled edges after accept); frame memories and
// serial window traversal remain area/throughput tradeoffs.
module img_dh_guided_refine #(
    parameter integer MAX_WIDTH = 64,
    parameter integer MAX_HEIGHT = 64,
    parameter integer MAX_RADIUS = 3,
    parameter integer DEPTH = (MAX_WIDTH > 0 && MAX_HEIGHT > 0) ? MAX_WIDTH*MAX_HEIGHT : 1,
    parameter integer ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input wire clk, rst_n, clk_en,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [15:0] cfg_width, cfg_height,
    input wire [3:0] cfg_radius,
    input wire [31:0] cfg_epsilon,
    input wire [7:0] s_guide_gray,
    input wire [15:0] s_t,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output reg [15:0] m_t,
    output reg m_valid, m_sof, m_eol, m_eof,
    input wire m_ready,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [3:0] rsp_error,
    // Verification tap; meaningful with m_valid, otherwise diagnostic only.
    output wire signed [63:0] debug_divide_quotient,
    output reg signed [47:0] debug_first_a_value,
    output reg signed [47:0] debug_first_b_value,
    // First synchronous coefficient-RAM read, sampled when B_ACC consumes b_q.
    output reg signed [47:0] debug_first_b_mem_readback,
    output reg [31:0] debug_first_sum_i,
    output reg [31:0] debug_first_sum_p,
    output reg [31:0] debug_first_sum_ii,
    output reg [31:0] debug_first_sum_ip,
    output reg [2:0] debug_frame_error_flags,
    output reg signed [63:0] debug_first_a_numerator,
    output reg signed [63:0] debug_first_a_denominator,
    output reg signed [63:0] debug_first_b_numerator,
    output reg signed [63:0] debug_first_b_denominator,
    // First B-division diagnostics captured from the divider's accepted start
    // and completion. These replace testbench-only hierarchical probes.
    output reg debug_first_b_div_start_seen,
    output reg debug_first_b_div_done_seen,
    output reg debug_first_b_dividend_negative,
    output reg debug_first_b_divisor_negative,
    output reg [6:0] debug_first_b_div_initial_bit_index,
    output reg [6:0] debug_first_b_div_wait_cycles,
    output reg [63:0] debug_first_b_dividend_magnitude,
    output reg [63:0] debug_first_b_divisor_magnitude,
    output reg [63:0] debug_first_b_div_quotient_magnitude,
    output reg [63:0] debug_first_b_div_remainder,
    output reg signed [63:0] debug_first_b_div_final_quotient,
    // First A-divider iteration trace. The legacy "first_b" prefix is kept
    // for compatibility; these taps describe the first A divide launched in
    // A_SOLVE. They observe divider state without changing its arithmetic.
    output reg [63:0] debug_first_b_div_actual_dividend_magnitude,
    output reg [63:0] debug_first_b_div_actual_divisor_magnitude,
    output reg [6:0] debug_first_b_div_final_bit_index,
    output reg [63:0] debug_first_b_div_current_remainder,
    output reg [63:0] debug_first_b_div_remainder_after_1,
    output reg [63:0] debug_first_b_div_remainder_after_32,
    // Compact first-B-division trace: acceptance/completion and final result.
    output reg debug_first_bsolve_div_start_seen,
    output reg debug_first_bsolve_div_done_seen,
    output reg [63:0] debug_first_bsolve_div_quotient_magnitude,
    output reg [63:0] debug_first_bsolve_div_final_remainder,
    output reg signed [63:0] debug_second_q_numerator,
    output reg signed [63:0] debug_second_q_denominator,
    output reg signed [63:0] debug_first_q_sum_a,
    output reg signed [63:0] debug_first_q_sum_b,
    output reg signed [63:0] debug_first_q_numerator,
    output reg signed [63:0] debug_first_q_denominator,
    output reg signed [47:0] debug_a_coeff_1,
    output reg signed [47:0] debug_a_coeff_3,
    output reg signed [47:0] debug_a_coeff_4,
    output reg signed [47:0] debug_b_coeff_1,
    output reg signed [47:0] debug_b_coeff_3,
    output reg signed [47:0] debug_b_coeff_4,
    output reg [31:0] debug_a3_sum_i,
    output reg [31:0] debug_a3_sum_p,
    output reg [31:0] debug_a3_sum_ii,
    output reg [31:0] debug_a3_sum_ip,
    output reg [31:0] debug_a4_sum_i,
    output reg [31:0] debug_a4_sum_p,
    output reg [31:0] debug_a4_sum_ii,
    output reg [31:0] debug_a4_sum_ip,
    output reg debug_first_bsolve_actual_trace_seen,
    output reg [63:0] debug_first_bsolve_actual_dividend_magnitude,
    output reg [63:0] debug_first_bsolve_actual_divisor_magnitude,
    output reg [63:0] debug_first_bsolve_actual_remainder,
    output reg debug_first_bsolve_actual_subtract
);
    localparam integer PARAM_OK = MAX_WIDTH>=1 && MAX_WIDTH<=512 &&
        MAX_HEIGHT>=1 && MAX_HEIGHT<=512 && MAX_RADIUS>=0 && MAX_RADIUS<=7 &&
        DEPTH>=MAX_WIDTH*MAX_HEIGHT && ADDR_W>=1 && ADDR_W<=20 &&
        DEPTH<=(32'd1<<ADDR_W);
    localparam [4:0] IDLE=0,CAPTURE=1,A_INIT=2,A_REQ=3,A_ACC=4,A_SOLVE=5,
        A_B=6,A_STORE=7,B_CENTER_REQ=8,B_CENTER_CAP=9,B_REQ=10,B_ACC=11,
        B_RESULT=12,B_OUTPUT=13,RESPONSE=14,A_SOLVE_WAIT=15,A_B_WAIT=16,
        B_RESULT_WAIT=17,
        A_SOURCE=18,A_PRODUCT=19,A_SUB_EPS=20,A_ADD=21,
        B_SOURCE=22,B_PRODUCT=23,B_SUB=24,
        Q_SOURCE=25,Q_PRODUCT=26,Q_ADD=27,B_MUL_WAIT=28,Q_MUL_WAIT=29,A_MUL_WAIT=30,A_SAMPLE=31;
    reg [4:0] state;
    reg [15:0] width,height,px,py;
    reg [31:0] count,total,index;
    reg [3:0] radius;
    reg [31:0] epsilon;
    reg [63:0] area;
    reg signed [5:0] dx,dy;
    reg frame_error;
    reg [63:0] sum_i,sum_p,sum_ii,sum_ip;
    reg signed [63:0] sum_a,sum_b;
    reg signed [47:0] a_value,b_value;
    reg [7:0] center_guide;
    (* ram_style="block", syn_ramstyle="block_ram" *) reg [23:0] input_mem[0:DEPTH-1];
    (* ram_style="block", syn_ramstyle="block_ram" *) reg signed [47:0] a_mem[0:DEPTH-1];
    (* ram_style="block", syn_ramstyle="block_ram" *) reg signed [47:0] b_mem[0:DEPTH-1];
    reg [23:0] input_q;
    reg signed [47:0] a_q,b_q;
    integer nx,ny;
    reg [31:0] neighbor_index;
    always @* begin
        nx = $signed({1'b0,px}) + $signed(dx);
        ny = $signed({1'b0,py}) + $signed(dy);
        if(nx<0) nx=0; else if(nx>=width) nx=width-1;
        if(ny<0) ny=0; else if(ny>=height) ny=height-1;
        neighbor_index = ny*width+nx;
    end
    wire input_fire = s_valid && s_ready;
    wire [31:0] input_read_index = (state==B_CENTER_REQ) ? index : neighbor_index;
    wire [7:0] q_guide = input_q[23:16];
    wire [15:0] q_t = input_q[15:0];
    wire last_neighbor = (dx==$signed({1'b0,radius})) &&
                         (dy==$signed({1'b0,radius}));
    assign cfg_ready = rst_n && clk_en && state==IDLE && !rsp_valid;
    assign s_ready = rst_n && clk_en && state==CAPTURE;
    // All coefficient and frame reads are edge-triggered. Never read an entire
    // frame array combinationally. No reset loop on the RAMs or their read q.
    always @(posedge clk) begin
        if(rst_n && clk_en) begin
            if(input_fire) input_mem[count[ADDR_W-1:0]] <= {s_guide_gray,s_t};
            if(state==A_REQ || state==B_CENTER_REQ)
                input_q <= input_mem[input_read_index[ADDR_W-1:0]];
            if(state==B_REQ) begin
                a_q <= a_mem[neighbor_index[ADDR_W-1:0]];
                b_q <= b_mem[neighbor_index[ADDR_W-1:0]];
            end
            if(state==A_STORE) begin
                a_mem[index[ADDR_W-1:0]] <= a_value;
                b_mem[index[ADDR_W-1:0]] <= b_value;
            end
        end
    end
    // v62: register every solve boundary before the signed-divider launch.
    // Captured source fields retain the original v52 narrowing/truncation.
    // No stage below reads live accumulators after its SOURCE edge.
    reg [2:0] a_mul_index;
    reg [15:0] guide_square_q;
    reg [23:0] guide_t_q;
    reg [7:0] solve_ni;
    reg [15:0] solve_si,solve_eps;
    reg [22:0] solve_sp;
    reg [23:0] solve_sii;
    reg [30:0] solve_sip;
    reg [38:0] solve_cross_ip,solve_cross_mean;
    reg [31:0] solve_ni_sii,solve_si_squared,solve_ni_squared_eps;
    reg [15:0] solve_ni_squared;
    reg signed [39:0] solve_covariance;
    reg signed [33:0] solve_den_difference;
    wire [63:0] prefix_covariance,prefix_den_difference,prefix_den_sum;
    wire signed [33:0] solve_den_sum=prefix_den_sum[33:0];
    reg signed [63:0] solve_area,solve_ac,solve_sa,solve_sb;
    reg [7:0] solve_guide;
    reg signed [63:0] solve_coefficient_product,solve_guide_product;
    reg signed [63:0] divide_numerator,divide_denominator;
    wire [63:0] prefix_sum_i,prefix_sum_p,prefix_sum_ii,prefix_sum_ip;
    wire [63:0] prefix_sum_a,prefix_sum_b,prefix_b_numerator,prefix_q_numerator;
    wire [63:0] q_guide_squared={48'd0,guide_square_q};
    wire [63:0] q_guide_t={40'd0,guide_t_q};
    img_dh_addsub64_prefix add_i(sum_i,{56'd0,q_guide},1'b0,prefix_sum_i);
    img_dh_addsub64_prefix add_p(sum_p,{48'd0,q_t},1'b0,prefix_sum_p);
    img_dh_addsub64_prefix add_ii(sum_ii,q_guide_squared,1'b0,prefix_sum_ii);
    img_dh_addsub64_prefix add_ip(sum_ip,q_guide_t,1'b0,prefix_sum_ip);
    img_dh_addsub64_prefix add_a(sum_a,{{16{a_q[47]}},a_q},1'b0,prefix_sum_a);
    img_dh_addsub64_prefix add_b(sum_b,{{16{b_q[47]}},b_q},1'b0,prefix_sum_b);
    img_dh_addsub64_prefix sub_b(({41'd0,solve_sp}<<16),solve_coefficient_product,1'b1,prefix_b_numerator);
    img_dh_addsub64_prefix add_q(solve_guide_product,solve_sb,1'b0,prefix_q_numerator);
    img_dh_addsub64_prefix subtract_covariance({25'd0,solve_cross_ip},{25'd0,solve_cross_mean},1'b1,prefix_covariance);
    img_dh_addsub64_prefix subtract_denominator({32'd0,solve_ni_sii},{32'd0,solve_si_squared},1'b1,prefix_den_difference);
    img_dh_addsub64_prefix add_denominator({{30{solve_den_difference[33]}},solve_den_difference},
        {32'd0,solve_ni_squared_eps},1'b0,prefix_den_sum);
    // One byte-serial multiplier is shared by all A, B and Q solve phases.
    // The nonnegative factor is captured at launch; live parent changes
    // during the 144-CE arithmetic operation cannot change the result.
    wire multiply_start=(state==A_PRODUCT || state==B_PRODUCT || state==Q_PRODUCT);
    reg [63:0] a_multiply_operand;
    reg [15:0] a_multiply_factor;
    always @* begin
        case(a_mul_index)
            0: begin a_multiply_operand={33'd0,solve_sip};a_multiply_factor={8'd0,solve_ni};end
            1: begin a_multiply_operand={41'd0,solve_sp};a_multiply_factor=solve_si;end
            2: begin a_multiply_operand={40'd0,solve_sii};a_multiply_factor={8'd0,solve_ni};end
            3: begin a_multiply_operand={48'd0,solve_si};a_multiply_factor=solve_si;end
            4: begin a_multiply_operand={56'd0,solve_ni};a_multiply_factor={8'd0,solve_ni};end
            default: begin a_multiply_operand={48'd0,solve_ni_squared};a_multiply_factor=solve_eps;end
        endcase
    end
    wire [63:0] multiply_operand=(state==A_PRODUCT) ? a_multiply_operand :
        ((state==B_PRODUCT) ? solve_ac : solve_sa);
    wire [15:0] multiply_factor=(state==A_PRODUCT) ? a_multiply_factor :
        ((state==B_PRODUCT) ? solve_si : {8'd0,solve_guide});
    wire multiply_busy,multiply_done;
    wire [63:0] multiply_product;
    img_dh_iter_mul64x16_byte u_solve_multiplier (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.start(multiply_start),
        .multiplicand(multiply_operand),.factor(multiply_factor),
        .busy(multiply_busy),.done(multiply_done),.product(multiply_product)
    );
    wire divide_start=(state==A_SOLVE || state==A_B || state==B_RESULT);
    wire divide_busy,divide_done;
    wire signed [63:0] divide_quotient;
    wire divider_start_accept;
    wire divider_debug_operands_ready;
    wire [6:0] divider_debug_start_bit_index;
    wire [6:0] divider_debug_bit_index;
    wire [63:0] divider_debug_dividend_magnitude,divider_debug_divisor_magnitude;
    wire [63:0] divider_debug_quotient_magnitude;
    wire [64:0] divider_debug_remainder;
    wire [64:0] divider_debug_shifted_remainder;
    wire divider_debug_subtract_divisor;
    assign debug_divide_quotient = divide_quotient;
    img_dh_iter_div_signed64 u_divider (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.start(divide_start),
        .dividend(divide_numerator),.divisor(divide_denominator),
        .busy(divide_busy),.done(divide_done),.quotient(divide_quotient),
        .start_accept(divider_start_accept),
        .debug_operands_ready(divider_debug_operands_ready),
        .debug_start_bit_index(divider_debug_start_bit_index),
        .debug_bit_index(divider_debug_bit_index),
        .debug_dividend_magnitude(divider_debug_dividend_magnitude),
        .debug_divisor_magnitude(divider_debug_divisor_magnitude),
        .debug_quotient_magnitude(divider_debug_quotient_magnitude),
        .debug_remainder(divider_debug_remainder),
        .debug_shifted_remainder(divider_debug_shifted_remainder),
        .debug_subtract_divisor(divider_debug_subtract_divisor)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;width<=0;height<=0;px<=0;py<=0;count<=0;total<=0;index<=0;
            radius<=0;epsilon<=1;area<=1;dx<=0;dy<=0;frame_error<=0;
            sum_i<=0;sum_p<=0;sum_ii<=0;sum_ip<=0;sum_a<=0;sum_b<=0;
            a_value<=0;b_value<=0;center_guide<=0;
            a_mul_index<=0;guide_square_q<=0;guide_t_q<=0;
            solve_ni<=0;solve_si<=0;solve_eps<=0;solve_sp<=0;
            solve_sii<=0;solve_sip<=0;
            solve_cross_ip<=0;solve_cross_mean<=0;
            solve_ni_sii<=0;solve_si_squared<=0;solve_ni_squared_eps<=0;
            solve_ni_squared<=0;solve_covariance<=0;solve_den_difference<=0;
            solve_area<=0;solve_ac<=0;solve_sa<=0;solve_sb<=0;solve_guide<=0;
            solve_coefficient_product<=0;solve_guide_product<=0;
            divide_numerator<=0;divide_denominator<=1;
            debug_first_a_value<=0;debug_first_b_value<=0;
            debug_first_b_mem_readback<=0;
            debug_first_sum_i<=0;debug_first_sum_p<=0;
            debug_first_sum_ii<=0;debug_first_sum_ip<=0;
            debug_frame_error_flags<=0;
            debug_first_a_numerator<=0;debug_first_a_denominator<=0;
            debug_first_b_numerator<=0;debug_first_b_denominator<=0;
            debug_first_b_div_start_seen<=0;debug_first_b_div_done_seen<=0;
            debug_first_b_dividend_negative<=0;debug_first_b_divisor_negative<=0;
            debug_first_b_div_initial_bit_index<=0;debug_first_b_div_wait_cycles<=0;
            debug_first_b_dividend_magnitude<=0;debug_first_b_divisor_magnitude<=0;
            debug_first_b_div_quotient_magnitude<=0;debug_first_b_div_remainder<=0;
            debug_first_b_div_final_quotient<=0;
            debug_first_b_div_actual_dividend_magnitude<=0;
            debug_first_b_div_actual_divisor_magnitude<=0;
            debug_first_b_div_final_bit_index<=0;
            debug_first_b_div_current_remainder<=0;
            debug_first_b_div_remainder_after_1<=0;
            debug_first_b_div_remainder_after_32<=0;
            debug_first_bsolve_div_start_seen<=0;debug_first_bsolve_div_done_seen<=0;
            debug_first_bsolve_div_quotient_magnitude<=0;
            debug_first_bsolve_div_final_remainder<=0;
            debug_first_bsolve_actual_trace_seen<=0;
            debug_first_bsolve_actual_dividend_magnitude<=0;
            debug_first_bsolve_actual_divisor_magnitude<=0;
            debug_first_bsolve_actual_remainder<=0;
            debug_first_bsolve_actual_subtract<=0;
            debug_second_q_numerator<=0;debug_second_q_denominator<=0;
            debug_first_q_sum_a<=0;debug_first_q_sum_b<=0;
            debug_first_q_numerator<=0;debug_first_q_denominator<=0;
            debug_a_coeff_1<=0;debug_a_coeff_3<=0;debug_a_coeff_4<=0;
            debug_b_coeff_1<=0;debug_b_coeff_3<=0;debug_b_coeff_4<=0;
            debug_a3_sum_i<=0;debug_a3_sum_p<=0;debug_a3_sum_ii<=0;debug_a3_sum_ip<=0;
            debug_a4_sum_i<=0;debug_a4_sum_p<=0;debug_a4_sum_ii<=0;debug_a4_sum_ip<=0;
            m_t<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;
            rsp_valid<=0;rsp_error<=0;
        end else if(clk_en) begin
            case(state)
                IDLE: if(cfg_valid && cfg_ready) begin
                    if(!PARAM_OK || cfg_width==0 || cfg_height==0 ||
                       cfg_width>MAX_WIDTH || cfg_height>MAX_HEIGHT ||
                       cfg_radius>MAX_RADIUS || cfg_epsilon==0 || cfg_epsilon>65535) begin
                        rsp_valid<=1;rsp_error<=1;state<=RESPONSE;
                    end else begin
                        width<=cfg_width;height<=cfg_height;radius<=cfg_radius;
                        epsilon<=cfg_epsilon;
                        area <= (64'd2*cfg_radius+1)*(64'd2*cfg_radius+1);
                        count<=0;total<=32'd1*cfg_width*cfg_height;index<=0;
                        px<=0;py<=0;frame_error<=0;state<=CAPTURE;
                        debug_first_sum_i<=0;debug_first_sum_p<=0;
                        debug_first_sum_ii<=0;debug_first_sum_ip<=0;
                        debug_first_b_mem_readback<=0;
                        debug_frame_error_flags<=0;
                        debug_first_a_numerator<=0;debug_first_a_denominator<=0;
                        debug_first_b_numerator<=0;debug_first_b_denominator<=0;
                        debug_first_b_div_start_seen<=0;debug_first_b_div_done_seen<=0;
                        debug_first_b_dividend_negative<=0;debug_first_b_divisor_negative<=0;
                        debug_first_b_div_initial_bit_index<=0;debug_first_b_div_wait_cycles<=0;
                        debug_first_b_dividend_magnitude<=0;debug_first_b_divisor_magnitude<=0;
                        debug_first_b_div_quotient_magnitude<=0;debug_first_b_div_remainder<=0;
                        debug_first_b_div_final_quotient<=0;
                        debug_first_b_div_actual_dividend_magnitude<=0;
                        debug_first_b_div_actual_divisor_magnitude<=0;
                        debug_first_b_div_final_bit_index<=0;
                        debug_first_b_div_current_remainder<=0;
                        debug_first_b_div_remainder_after_1<=0;
                        debug_first_b_div_remainder_after_32<=0;
                        debug_first_bsolve_div_start_seen<=0;debug_first_bsolve_div_done_seen<=0;
                        debug_first_bsolve_div_quotient_magnitude<=0;
                        debug_first_bsolve_div_final_remainder<=0;
                        debug_first_bsolve_actual_trace_seen<=0;
                        debug_first_bsolve_actual_dividend_magnitude<=0;
                        debug_first_bsolve_actual_divisor_magnitude<=0;
                        debug_first_bsolve_actual_remainder<=0;
                        debug_first_bsolve_actual_subtract<=0;
                        debug_second_q_numerator<=0;debug_second_q_denominator<=0;
                        debug_first_q_sum_a<=0;debug_first_q_sum_b<=0;
                        debug_first_q_numerator<=0;debug_first_q_denominator<=0;
                        debug_a_coeff_1<=0;debug_a_coeff_3<=0;debug_a_coeff_4<=0;
                        debug_b_coeff_1<=0;debug_b_coeff_3<=0;debug_b_coeff_4<=0;
                        debug_a3_sum_i<=0;debug_a3_sum_p<=0;debug_a3_sum_ii<=0;debug_a3_sum_ip<=0;
                        debug_a4_sum_i<=0;debug_a4_sum_p<=0;debug_a4_sum_ii<=0;debug_a4_sum_ip<=0;
                    end
                end
                CAPTURE: if(input_fire) begin
                    if(s_sof !== (count==0)) begin
                        frame_error<=1;
                        debug_frame_error_flags[0]<=1;
                    end
                    if(s_eol !== (px==width-1)) begin
                        frame_error<=1;
                        debug_frame_error_flags[1]<=1;
                    end
                    if(s_t>32768) begin
                        frame_error<=1;
                        debug_frame_error_flags[2]<=1;
                    end
                    if(count==total-1) begin
                        px<=0;py<=0;index<=0;state<=A_INIT;
                    end else begin
                        count<=count+1'b1;
                        if(px==width-1) begin px<=0;py<=py+1'b1;end
                        else px<=px+1'b1;
                    end
                end
                A_INIT: begin
                    dx<=-$signed({1'b0,radius});dy<=-$signed({1'b0,radius});
                    sum_i<=0;sum_p<=0;sum_ii<=0;sum_ip<=0;state<=A_REQ;
                end
                A_REQ: state<=A_SAMPLE;
                A_SAMPLE: begin
                    guide_square_q<=q_guide*q_guide;
                    guide_t_q<=q_guide*q_t;
                    state<=A_ACC;
                end
                A_ACC: begin
                    sum_i<=prefix_sum_i;sum_p<=prefix_sum_p;
                    sum_ii<=prefix_sum_ii;
                    sum_ip<=prefix_sum_ip;
                    if(last_neighbor) state<=A_SOURCE;
                    else begin
                        if(dx==$signed({1'b0,radius})) begin
                            dx<=-$signed({1'b0,radius});dy<=dy+1'b1;
                        end else dx<=dx+1'b1;
                        state<=A_REQ;
                    end
                end
                A_SOURCE: begin
                    solve_ni<=area[7:0];solve_si<=sum_i[15:0];
                    solve_sp<=sum_p[22:0];solve_sii<=sum_ii[23:0];
                    solve_sip<=sum_ip[30:0];solve_eps<=epsilon[15:0];a_mul_index<=0;
                    state<=A_PRODUCT;
                end
                A_PRODUCT: state<=A_MUL_WAIT;
                A_MUL_WAIT: if(multiply_done) begin
                    // Retain the original narrowed product widths exactly.
                    case(a_mul_index)
                        0: solve_cross_ip<=multiply_product[38:0];
                        1: solve_cross_mean<=multiply_product[38:0];
                        2: solve_ni_sii<=multiply_product[31:0];
                        3: solve_si_squared<=multiply_product[31:0];
                        4: solve_ni_squared<=multiply_product[15:0];
                        5: solve_ni_squared_eps<=multiply_product[31:0];
                    endcase
                    if(a_mul_index==5) state<=A_SUB_EPS;
                    else begin a_mul_index<=a_mul_index+1'b1;state<=A_PRODUCT;end
                end
                A_SUB_EPS: begin
                    solve_covariance<=prefix_covariance[39:0];
                    solve_den_difference<=prefix_den_difference[33:0];
                    state<=A_ADD;
                end
                A_ADD: begin
                    // Preserve signed 40-bit covariance and 34-bit denominator
                    // before sign extension; the 64-bit left shift truncates.
                    divide_numerator<=$signed({{24{solve_covariance[39]}},solve_covariance})<<<16;
                    divide_denominator<=solve_den_sum;
                    state<=A_SOLVE;
                end
                A_SOLVE: begin
                    if(index==0) begin
                        debug_first_sum_i<=sum_i[31:0];
                        debug_first_sum_p<=sum_p[31:0];
                        debug_first_sum_ii<=sum_ii[31:0];
                        debug_first_sum_ip<=sum_ip[31:0];
                        debug_first_a_numerator<=divide_numerator;
                        debug_first_a_denominator<=divide_denominator;
                        if(divider_start_accept) begin
                            debug_first_b_div_start_seen<=1;
                            debug_first_b_dividend_negative<=divide_numerator[63];
                            debug_first_b_divisor_negative<=divide_denominator[63];
                            debug_first_b_dividend_magnitude<=divide_numerator[63] ?
                                (~divide_numerator+64'd1):divide_numerator;
                            debug_first_b_divisor_magnitude<=divide_denominator[63] ?
                                (~divide_denominator+64'd1):divide_denominator;
                            debug_first_b_div_wait_cycles<=0;
                        end
                    end
                    if(index==3) begin
                        debug_a3_sum_i<=sum_i[31:0];
                        debug_a3_sum_p<=sum_p[31:0];
                        debug_a3_sum_ii<=sum_ii[31:0];
                        debug_a3_sum_ip<=sum_ip[31:0];
                    end
                    if(index==4) begin
                        debug_a4_sum_i<=sum_i[31:0];
                        debug_a4_sum_p<=sum_p[31:0];
                        debug_a4_sum_ii<=sum_ii[31:0];
                        debug_a4_sum_ip<=sum_ip[31:0];
                    end
                    state<=A_SOLVE_WAIT;
                end
                A_SOLVE_WAIT: begin
                    if(index==0 && divide_busy && divider_debug_operands_ready && !divide_done &&
                       debug_first_b_div_wait_cycles!=7'h7f)
                        debug_first_b_div_wait_cycles<=debug_first_b_div_wait_cycles+1'b1;
                    // wait_cycles counts enabled quotient iterations only;
                    // the operand-normalization CE is deliberately excluded.
                    if(index==0 && divide_busy && divider_debug_operands_ready &&
                       debug_first_b_div_wait_cycles==0) begin
                        debug_first_b_div_actual_dividend_magnitude<=divider_debug_dividend_magnitude;
                        debug_first_b_div_actual_divisor_magnitude<=divider_debug_divisor_magnitude;
                    end
                    if(index==0 && divide_busy && divider_debug_operands_ready &&
                       debug_first_b_div_wait_cycles==1)
                        debug_first_b_div_remainder_after_1<=divider_debug_remainder[63:0];
                    if(index==0 && divide_busy && divider_debug_operands_ready &&
                       debug_first_b_div_wait_cycles==32)
                        debug_first_b_div_remainder_after_32<=divider_debug_remainder[63:0];
                    if(divide_done) begin
                        if(index==0) begin
                            debug_first_b_div_done_seen<=1;
                            debug_first_b_div_initial_bit_index<=divider_debug_start_bit_index;
                            debug_first_b_div_final_bit_index<=divider_debug_bit_index;
                            debug_first_b_div_quotient_magnitude<=divider_debug_quotient_magnitude;
                            debug_first_b_div_remainder<=divider_debug_remainder[63:0];
                            debug_first_b_div_current_remainder<=divider_debug_remainder[63:0];
                            debug_first_b_div_final_quotient<=divide_quotient;
                        end
                        a_value<=divide_quotient[47:0];state<=B_SOURCE;
                    end
                end
                B_SOURCE: begin
                    solve_si<=sum_i[15:0];solve_sp<=sum_p[22:0];
                    solve_ac<=a_value;solve_area<=$signed(area);
                    state<=B_PRODUCT;
                end
                B_PRODUCT: state<=B_MUL_WAIT;
                B_MUL_WAIT: if(multiply_done) begin
                    solve_coefficient_product<=multiply_product;
                    state<=B_SUB;
                end
                B_SUB: begin
                    divide_numerator<=prefix_b_numerator;
                    divide_denominator<=solve_area;
                    state<=A_B;
                end
                A_B: begin
                    if(index==0) begin
                        debug_first_b_numerator<=divide_numerator;
                        debug_first_b_denominator<=divide_denominator;
                        if(divider_start_accept)
                            debug_first_bsolve_div_start_seen<=1;
                    end
                    state<=A_B_WAIT;
                end
                A_B_WAIT: begin
                    // Snapshot the loaded operands and first iteration decision
                    // only after the registered operands have been normalized.
                    // These taps do not feed the datapath or alter divider timing.
                    if(index==0 && divide_busy && divider_debug_operands_ready && !divide_done &&
                       !debug_first_bsolve_actual_trace_seen) begin
                        debug_first_bsolve_actual_trace_seen<=1;
                        debug_first_bsolve_actual_dividend_magnitude<=divider_debug_dividend_magnitude;
                        debug_first_bsolve_actual_divisor_magnitude<=divider_debug_divisor_magnitude;
                        debug_first_bsolve_actual_remainder<=divider_debug_remainder[63:0];
                        debug_first_bsolve_actual_subtract<=divider_debug_subtract_divisor;
                    end
                    if(divide_done) begin
                        if(index==0) begin
                            debug_first_bsolve_div_done_seen<=1;
                            debug_first_bsolve_div_quotient_magnitude<=divider_debug_quotient_magnitude;
                            debug_first_bsolve_div_final_remainder<=divider_debug_remainder[63:0];
                        end
                        b_value<=divide_quotient[47:0];state<=A_STORE;
                    end
                end
                A_STORE: begin
                    if(index==0) begin
                        debug_first_a_value<=a_value;
                        debug_first_b_value<=b_value;
                    end
                    if(index==1) begin debug_a_coeff_1<=a_value;debug_b_coeff_1<=b_value;end
                    if(index==3) begin debug_a_coeff_3<=a_value;debug_b_coeff_3<=b_value;end
                    if(index==4) begin debug_a_coeff_4<=a_value;debug_b_coeff_4<=b_value;end
                    if(index==total-1) begin px<=0;py<=0;index<=0;state<=B_CENTER_REQ;end
                    else begin
                        index<=index+1'b1;
                        if(px==width-1) begin px<=0;py<=py+1'b1;end
                        else px<=px+1'b1;
                        state<=A_INIT;
                    end
                end
                B_CENTER_REQ: state<=B_CENTER_CAP;
                B_CENTER_CAP: begin
                    center_guide<=q_guide;sum_a<=0;sum_b<=0;
                    dx<=-$signed({1'b0,radius});dy<=-$signed({1'b0,radius});state<=B_REQ;
                end
                B_REQ: state<=B_ACC;
                B_ACC: begin
                    // B_REQ issued the synchronous b_mem read one cycle earlier;
                    // capture the value actually consumed for the first pixel.
                    if(index==0 && dx==-$signed({1'b0,radius}) &&
                       dy==-$signed({1'b0,radius}))
                        debug_first_b_mem_readback<=b_q;
                    sum_a<=prefix_sum_a;sum_b<=prefix_sum_b;
                    if(last_neighbor) state<=Q_SOURCE;
                    else begin
                        if(dx==$signed({1'b0,radius})) begin
                            dx<=-$signed({1'b0,radius});dy<=dy+1'b1;
                        end else dx<=dx+1'b1;
                        state<=B_REQ;
                    end
                end
                Q_SOURCE: begin
                    solve_sa<=sum_a;solve_sb<=sum_b;solve_guide<=center_guide;
                    solve_area<=$signed(area<<16);
                    state<=Q_PRODUCT;
                end
                Q_PRODUCT: state<=Q_MUL_WAIT;
                Q_MUL_WAIT: if(multiply_done) begin
                    solve_guide_product<=multiply_product;
                    state<=Q_ADD;
                end
                Q_ADD: begin
                    divide_numerator<=prefix_q_numerator;
                    divide_denominator<=solve_area;
                    state<=B_RESULT;
                end
                B_RESULT: begin
                    if(index==0) begin
                        debug_first_q_sum_a<=sum_a;
                        debug_first_q_sum_b<=sum_b;
                        debug_first_q_numerator<=divide_numerator;
                        debug_first_q_denominator<=divide_denominator;
                    end
                    if(index==1) begin
                        debug_second_q_numerator<=divide_numerator;
                        debug_second_q_denominator<=divide_denominator;
                    end
                    state<=B_RESULT_WAIT;
                end
                B_RESULT_WAIT: if(divide_done) begin
                    if(divide_quotient<0) m_t<=0;
                    else if(divide_quotient>64'sd32768) m_t<=16'd32768;
                    else m_t<=divide_quotient[15:0];
                    m_sof<=(index==0);m_eol<=(px==width-1);m_eof<=(index==total-1);
                    m_valid<=1;state<=B_OUTPUT;
                end
                B_OUTPUT: if(m_valid && m_ready) begin
                    m_valid<=0;
                    if(index==total-1) begin
                        rsp_valid<=1;rsp_error<=frame_error ? 4'd2 : 4'd0;state<=RESPONSE;
                    end else begin
                        index<=index+1'b1;
                        if(px==width-1) begin px<=0;py<=py+1'b1;end
                        else px<=px+1'b1;
                        state<=B_CENTER_REQ;
                    end
                end
                RESPONSE: if(rsp_valid && rsp_ready) begin rsp_valid<=0;state<=IDLE;end
                default: begin m_valid<=0;rsp_valid<=1;rsp_error<=3;state<=RESPONSE;end
            endcase
        end
    end
endmodule

// Byte-serial divider keeps each arithmetic chunk at eight bits.
// Signed restoring division with one eight-bit arithmetic chunk per CE edge.
// Nonzero divisors only. MIN_INT / -1 wraps modulo 2^64, as in the previous
// core. Start-to-done is 656 enabled edges after the acceptance edge.
// Debug subtraction is valid in COMMIT; bit_index changes once per quotient bit.
module img_dh_iter_div_signed64 (
    input wire clk,rst_n,clk_en,start,
    input wire signed [63:0] dividend,divisor,
    output reg busy,done,
    output reg signed [63:0] quotient,
    output wire start_accept,debug_operands_ready,
    output reg [6:0] debug_start_bit_index,
    output wire [6:0] debug_bit_index,
    output wire [63:0] debug_dividend_magnitude,debug_divisor_magnitude,
    output wire [63:0] debug_quotient_magnitude,
    output wire [64:0] debug_remainder,debug_shifted_remainder,
    output wire debug_subtract_divisor
);
    localparam NORMALIZE=0,SETUP=1,SUBTRACT=2,COMMIT=3,FINISH=4;
    reg [2:0] phase,byte_index;
    reg [6:0] bit_index;
    reg dividend_negative,divisor_negative,quotient_negative;
    reg carry_a,carry_b,borrow,finish_carry;
    reg [63:0] dividend_operand,divisor_operand;
    reg [63:0] dividend_magnitude,divisor_magnitude,quotient_magnitude;
    reg [63:0] remainder,trial_work,divisor_work,difference_q;
    reg [63:0] finish_work,finish_q;
    wire operands_pending=busy && phase==NORMALIZE;
    wire [8:0] normalize_a=dividend_negative ?
        {1'b0,~dividend_operand[7:0]}+{8'b0,carry_a} : {1'b0,dividend_operand[7:0]};
    wire [8:0] normalize_b=divisor_negative ?
        {1'b0,~divisor_operand[7:0]}+{8'b0,carry_b} : {1'b0,divisor_operand[7:0]};
    wire [8:0] byte_difference={1'b0,trial_work[7:0]}-
        {1'b0,divisor_work[7:0]}-{8'b0,borrow};
    wire [8:0] finish_byte=quotient_negative ?
        {1'b0,~finish_work[7:0]}+{8'b0,finish_carry} : {1'b0,finish_work[7:0]};
    wire [63:0] quotient_magnitude_next={quotient_magnitude[62:0],!borrow};
    assign start_accept=clk_en && start && !busy;
    assign debug_operands_ready=busy && phase!=NORMALIZE;
    assign debug_bit_index=bit_index;
    assign debug_dividend_magnitude=dividend_magnitude;
    assign debug_divisor_magnitude=divisor_magnitude;
    assign debug_quotient_magnitude=quotient_magnitude;
    assign debug_remainder={1'b0,remainder};
    assign debug_shifted_remainder={remainder,dividend_magnitude[63]};
    assign debug_subtract_divisor=(phase==COMMIT) && !borrow;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            busy<=0;done<=0;quotient<=0;phase<=NORMALIZE;byte_index<=0;bit_index<=0;
            dividend_negative<=0;divisor_negative<=0;quotient_negative<=0;
            carry_a<=0;carry_b<=0;borrow<=0;finish_carry<=0;
            dividend_operand<=0;divisor_operand<=0;
            dividend_magnitude<=0;divisor_magnitude<=0;quotient_magnitude<=0;
            remainder<=0;trial_work<=0;divisor_work<=0;difference_q<=0;
            finish_work<=0;finish_q<=0;debug_start_bit_index<=0;
        end else if(clk_en) begin
            done<=0;
            if(start && !busy) begin
                busy<=1;phase<=NORMALIZE;byte_index<=0;bit_index<=63;
                dividend_operand<=dividend;divisor_operand<=divisor;
                dividend_negative<=dividend[63];divisor_negative<=divisor[63];
                quotient_negative<=dividend[63]^divisor[63];
                carry_a<=1;carry_b<=1;dividend_magnitude<=0;divisor_magnitude<=0;
                quotient_magnitude<=0;remainder<=0;debug_start_bit_index<=63;
            end else if(busy) case(phase)
                NORMALIZE: begin
                    dividend_operand<={8'b0,dividend_operand[63:8]};
                    divisor_operand<={8'b0,divisor_operand[63:8]};
                    dividend_magnitude<={normalize_a[7:0],dividend_magnitude[63:8]};
                    divisor_magnitude<={normalize_b[7:0],divisor_magnitude[63:8]};
                    carry_a<=normalize_a[8];carry_b<=normalize_b[8];
                    if(byte_index==7) begin phase<=SETUP;byte_index<=0;end
                    else byte_index<=byte_index+1'b1;
                end
                SETUP: begin
                    trial_work<={remainder[62:0],dividend_magnitude[63]};
                    divisor_work<=divisor_magnitude;borrow<=0;byte_index<=0;
                    phase<=SUBTRACT;
                end
                SUBTRACT: begin
                    trial_work<={8'b0,trial_work[63:8]};
                    divisor_work<={8'b0,divisor_work[63:8]};
                    difference_q<={byte_difference[7:0],difference_q[63:8]};
                    borrow<=byte_difference[8];
                    if(byte_index==7) begin phase<=COMMIT;byte_index<=0;end
                    else byte_index<=byte_index+1'b1;
                end
                COMMIT: begin
                    remainder<=borrow ? {remainder[62:0],dividend_magnitude[63]} : difference_q;
                    dividend_magnitude<={dividend_magnitude[62:0],1'b0};
                    quotient_magnitude<=quotient_magnitude_next;
                    if(bit_index==0) begin
                        finish_work<=quotient_magnitude_next;finish_carry<=1;
                        byte_index<=0;phase<=FINISH;
                    end else begin bit_index<=bit_index-1'b1;phase<=SETUP;end
                end
                FINISH: begin
                    finish_work<={8'b0,finish_work[63:8]};
                    finish_q<={finish_byte[7:0],finish_q[63:8]};
                    finish_carry<=finish_byte[8];
                    if(byte_index==7) begin
                        quotient<={finish_byte[7:0],finish_q[63:8]};
                        busy<=0;done<=1;
                    end else byte_index<=byte_index+1'b1;
                end
                default: begin busy<=0;done<=0;end
            endcase
        end
    end
endmodule


// Exact modulo-2^64 add/subtract with retained nibble prefix boundaries.
// No registers or added arithmetic latency. sub=1 gives a-b.
module img_dh_addsub64_prefix(
    input wire [63:0] a,b,
    input wire sub,
    output wire [63:0] result
);
    wire [63:0] adjusted_b=b^{64{sub}};
    (* keep = 1 *) wire [15:0] group_p[0:4];
    (* keep = 1 *) wire [15:0] group_g[0:4];
    wire [16:0] carry;
    assign carry[0]=sub;
    genvar nibble,level;
    generate for(nibble=0;nibble<16;nibble=nibble+1) begin: leaf
        wire [3:0] av=a[4*nibble+:4],bv=adjusted_b[4*nibble+:4];
        wire [4:0] local_sum={1'b0,av}+{1'b0,bv};
        assign group_p[0][nibble]=&(av^bv);
        assign group_g[0][nibble]=local_sum[4];
        assign carry[nibble+1]=group_g[4][nibble] | (group_p[4][nibble] & sub);
        assign result[4*nibble+:4]=av+bv+carry[nibble];
    end
    for(level=0;level<4;level=level+1) begin: prefix_level
        for(nibble=0;nibble<16;nibble=nibble+1) begin: prefix_node
            if(nibble >= (1<<level)) begin: combine
                assign group_g[level+1][nibble]=group_g[level][nibble] |
                    (group_p[level][nibble] & group_g[level][nibble-(1<<level)]);
                assign group_p[level+1][nibble]=group_p[level][nibble] &
                    group_p[level][nibble-(1<<level)];
            end else begin: pass
                assign group_g[level+1][nibble]=group_g[level][nibble];
                assign group_p[level+1][nibble]=group_p[level][nibble];
            end
        end
    end endgenerate
endmodule


// Exact low 64 bits of a 64-bit two's-complement bit pattern times an
// unsigned 16-bit factor. Each of 16 shift/add steps uses eight registered
// byte additions. Completion is 144 CE edges after the acceptance edge.
// No inferred wide multiply, carry chain or DSP is required.
module img_dh_iter_mul64x16_byte (
    input wire clk, rst_n, clk_en, start,
    input wire [63:0] multiplicand,
    input wire [15:0] factor,
    output reg busy, done,
    output reg [63:0] product
);
    reg adding;
    reg [3:0] bit_index;
    reg [2:0] byte_index;
    reg [63:0] multiplicand_base, addend_work, accumulator;
    reg [15:0] factor_q;
    reg carry;
    wire [7:0] addend_byte = factor_q[0] ? addend_work[7:0] : 8'd0;
    wire [8:0] byte_sum = {1'b0,accumulator[7:0]} +
                           {1'b0,addend_byte} + {8'd0,carry};
    wire [63:0] accumulator_next = {byte_sum[7:0],accumulator[63:8]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy<=0; done<=0; product<=0; adding<=0;
            bit_index<=0; byte_index<=0; carry<=0;
            multiplicand_base<=0; addend_work<=0; accumulator<=0; factor_q<=0;
        end else if (clk_en) begin
            done<=0;
            if (start && !busy) begin
                busy<=1; adding<=0; bit_index<=0; byte_index<=0; carry<=0;
                multiplicand_base<=multiplicand; factor_q<=factor; accumulator<=0;
            end else if (busy) begin
                if (!adding) begin
                    addend_work<=multiplicand_base;
                    carry<=0; byte_index<=0; adding<=1;
                end else begin
                    accumulator<=accumulator_next;
                    addend_work<={8'd0,addend_work[63:8]};
                    carry<=byte_sum[8];
                    if (byte_index==7) begin
                        if (bit_index==15) begin
                            product<=accumulator_next; busy<=0; done<=1;
                        end else begin
                            multiplicand_base<={multiplicand_base[62:0],1'b0};
                            factor_q<={1'b0,factor_q[15:1]};
                            bit_index<=bit_index+1'b1; adding<=0;
                        end
                    end else byte_index<=byte_index+1'b1;
                end
            end
        end
    end
endmodule

