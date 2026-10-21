`timescale 1ns/1ps
module tb_img_dh_solve_pipeline;
    reg clk=0,rst_n=0,clk_en=0;
    integer cases=0, a_cases=0,b_cases=0,q_cases=0,pause_cycles=0;
    integer wait_index,phase_index;
    integer k,seed=32'h6d123a71;
    reg [63:0] ni,si,sp,sii,sip,sa,sb;
    reg [31:0] eps;
    reg signed [47:0] av;
    reg [7:0] guide;
    reg signed [63:0] expected_num,expected_den;
    reg [1535:0] snapshot;
    always #5 clk=~clk;
    img_dh_guided_refine #(.MAX_WIDTH(1),.MAX_HEIGHT(1),.MAX_RADIUS(7)) dut(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .cfg_valid(1'b0),.cfg_width(16'd1),.cfg_height(16'd1),
        .cfg_radius(4'd0),.cfg_epsilon(32'd1),
        .s_guide_gray(8'd0),.s_t(16'd0),.s_valid(1'b0),.s_sof(1'b0),.s_eol(1'b0),
        .m_ready(1'b0),.rsp_ready(1'b0)
    );
    // Frozen v52 functions are the reference, independent of the new stages.
    function signed [63:0] solve_a_numerator;
        input [63:0] ni,si,sp,sii,sip;
        input [31:0] eps;
        // Validated configuration bounds make ni<=225, si<=57375,
        // sp<=7,372,800 and sip<=1,880,064,000. Keep the two cross-products
        // at their exact 39-bit width and the covariance signed at 40 bits;
        // a full 64x64 multiply was not bit-exact in the GW5A mapping.
        reg [38:0] cross_ip,cross_mean;
        reg signed [39:0] covariance;
        begin
            cross_ip = {31'd0,ni[7:0]} * {8'd0,sip[30:0]};
            cross_mean = {23'd0,si[15:0]} * {16'd0,sp[22:0]};
            covariance = $signed({1'b0,cross_ip}) -
                         $signed({1'b0,cross_mean});
            solve_a_numerator =
                $signed({{24{covariance[39]}},covariance}) <<< 16;
        end
    endfunction
    function signed [63:0] solve_a_denominator;
        input [63:0] ni,si,sii;
        input [31:0] eps;
        reg [31:0] ni_sii,si_squared,ni_squared_eps;
        reg [15:0] ni_squared;
        reg signed [33:0] denominator_value;
        begin
            ni_sii = {24'd0,ni[7:0]} * {8'd0,sii[23:0]};
            si_squared = {16'd0,si[15:0]} * {16'd0,si[15:0]};
            ni_squared = {8'd0,ni[7:0]} * {8'd0,ni[7:0]};
            ni_squared_eps = {16'd0,ni_squared} * {16'd0,eps[15:0]};
            denominator_value = $signed({2'b00,ni_sii}) -
                                $signed({2'b00,si_squared}) +
                                $signed({2'b00,ni_squared_eps});
            solve_a_denominator = denominator_value;
        end
    endfunction
    function signed [63:0] solve_b_numerator;
        input [63:0] si,sp;
        input signed [47:0] av;
        reg signed [63:0] ac,si_extended,sp_extended,coefficient_product;
        begin
            ac=av;
            si_extended=$signed({48'd0,si[15:0]});
            sp_extended=$signed({41'd0,sp[22:0]}) <<< 16;
            coefficient_product=ac*si_extended;
            solve_b_numerator=sp_extended-coefficient_product;
        end
    endfunction
    function signed [63:0] solve_q_numerator;
        input signed [63:0] sa,sb;
        input [7:0] guide;
        begin
            solve_q_numerator=sa*$signed({1'b0,guide})+sb;
        end
    endfunction


    function [1535:0] pipeline_snapshot;
        begin pipeline_snapshot={dut.state,dut.solve_ni,dut.solve_si,dut.solve_eps,
            dut.solve_sp,dut.solve_sii,dut.solve_sip,dut.solve_cross_ip,dut.solve_cross_mean,
            dut.solve_ni_sii,dut.solve_si_squared,dut.solve_ni_squared_eps,dut.solve_ni_squared,
            dut.solve_covariance,dut.solve_den_difference,dut.solve_area,dut.solve_ac,
            dut.solve_sa,dut.solve_sb,dut.solve_guide,dut.solve_coefficient_product,
            dut.solve_guide_product,dut.divide_numerator,dut.divide_denominator,
            dut.u_divider.busy,dut.u_divider.done,dut.u_divider.dividend_operand,
            dut.u_divider.divisor_operand,dut.u_divider.quotient_negative};end
    endfunction
    task pause_stage;
        begin
            clk_en=0;snapshot=pipeline_snapshot();
            repeat(2) begin
                @(posedge clk);#1;
                if(pipeline_snapshot()!==snapshot || dut.divider_start_accept!==0)
                    $fatal(1,"CE pause changed stage=%0d case=%0d",dut.state,cases);
                pause_cycles=pause_cycles+1;
                @(negedge clk);
            end
        end
    endtask
    task step_to;
        input [4:0] next_state;
        begin
            pause_stage();clk_en=1;
            @(posedge clk);#1;
            if(dut.state!==next_state)
                $fatal(1,"wrong stage case=%0d expected=%0d got=%0d",cases,next_state,dut.state);
            @(negedge clk);clk_en=0;
        end
    endtask
    task reset_case;
        begin
            @(negedge clk);rst_n=0;clk_en=0;
            @(negedge clk);rst_n=1;
            dut.area=ni;dut.sum_i=si;dut.sum_p=sp;dut.sum_ii=sii;dut.sum_ip=sip;
            dut.epsilon=eps;dut.a_value=av;dut.sum_a=sa;dut.sum_b=sb;dut.center_guide=guide;
        end
    endtask
    task disturb_live_sources;
        begin
            dut.area=64'h0123456789abcdef;dut.sum_i=~si;dut.sum_p=~sp;
            dut.sum_ii=~sii;dut.sum_ip=~sip;dut.epsilon=~eps;
            dut.a_value=~av;dut.sum_a=~sa;dut.sum_b=~sb;dut.center_guide=~guide;
        end
    endtask
    task check_launch;
        input [4:0] launch_state, wait_state;
        begin
            if(dut.state!==launch_state || dut.divide_start!==1 ||
                dut.divide_numerator!==expected_num || dut.divide_denominator!==expected_den)
                $fatal(1,"solve mismatch case=%0d kind=%0d num=%016x expected=%016x den=%016x expected=%016x",
                    cases,launch_state,dut.divide_numerator,expected_num,dut.divide_denominator,expected_den);
            pause_stage();clk_en=1;
            if(!dut.divider_start_accept) #0;
            @(posedge clk);#1;
            if(dut.state!==wait_state || dut.u_divider.dividend_operand!==expected_num ||
                dut.u_divider.divisor_operand!==expected_den || !dut.u_divider.operands_pending ||
                dut.u_divider.quotient_negative!==(expected_num[63]^expected_den[63]))
                $fatal(1,"divider accepted wrong registered operands case=%0d",cases);
            cases=cases+1;
            @(negedge clk);clk_en=0;
        end
    endtask
    task run_three;
        begin
            expected_num=solve_a_numerator(ni,si,sp,sii,sip,eps);
            expected_den=solve_a_denominator(ni,si,sii,eps);
            reset_case();dut.state=dut.A_SOURCE;
            step_to(dut.A_PRODUCT);disturb_live_sources();
            for(phase_index=0;phase_index<6;phase_index=phase_index+1) begin
                step_to(dut.A_MUL_WAIT);
                for(wait_index=0;wait_index<144;wait_index=wait_index+1) step_to(dut.A_MUL_WAIT);
                if(phase_index==5) step_to(dut.A_SUB_EPS);else step_to(dut.A_PRODUCT);
            end
            step_to(dut.A_ADD);step_to(dut.A_SOLVE);
            check_launch(dut.A_SOLVE,dut.A_SOLVE_WAIT);a_cases=a_cases+1;
            expected_num=solve_b_numerator(si,sp,av);expected_den=$signed(ni);
            reset_case();dut.state=dut.B_SOURCE;
            step_to(dut.B_PRODUCT);disturb_live_sources();step_to(dut.B_MUL_WAIT);
            for(wait_index=0;wait_index<144;wait_index=wait_index+1) step_to(dut.B_MUL_WAIT);
            step_to(dut.B_SUB);step_to(dut.A_B);
            check_launch(dut.A_B,dut.A_B_WAIT);b_cases=b_cases+1;
            expected_num=solve_q_numerator(sa,sb,guide);expected_den=$signed(ni<<16);
            reset_case();dut.state=dut.Q_SOURCE;
            step_to(dut.Q_PRODUCT);disturb_live_sources();step_to(dut.Q_MUL_WAIT);
            for(wait_index=0;wait_index<144;wait_index=wait_index+1) step_to(dut.Q_MUL_WAIT);
            step_to(dut.Q_ADD);step_to(dut.B_RESULT);
            check_launch(dut.B_RESULT,dut.B_RESULT_WAIT);q_cases=q_cases+1;
        end
    endtask
    initial begin
        ni=1;si=0;sp=0;sii=0;sip=0;eps=1;av=0;sa=0;sb=0;guide=0;run_three();
        ni=225;si=57375;sp=7372800;sii=14630625;sip=1880064000;eps=65535;
        av=48'sh7fffffffffff;sa=64'sh7fffffffffffffff;sb=64'sh7fffffffffffffff;guide=255;run_three();
        ni=225;si=57375;sp=7372800;sii=14630625;sip=1880064000;eps=65535;
        av=48'sh800000000000;sa=64'sh8000000000000000;sb=64'sh8000000000000000;guide=255;run_three();
        ni=64'hffffffffffffffff;si=ni;sp=ni;sii=ni;sip=ni;eps=32'hffffffff;
        av=-1;sa=-1;sb=-1;guide=255;run_three();
        ni=0;si=0;sp=0;sii=0;sip=0;eps=0;av=0;sa=0;sb=0;guide=0;run_three();
        ni=64'h8000000000000000;si=64'hffff;sp=64'h7fffff;sii=64'hffffff;sip=64'h7fffffff;
        eps=1;av=-65536;sa=-65536;sb=65536;guide=1;run_three();
        for(k=0;k<256;k=k+1) begin
            ni={$random(seed),$random(seed)};si={$random(seed),$random(seed)};
            sp={$random(seed),$random(seed)};sii={$random(seed),$random(seed)};
            sip={$random(seed),$random(seed)};eps=$random(seed);
            av={$random(seed),$random(seed)};sa={$random(seed),$random(seed)};
            sb={$random(seed),$random(seed)};guide=$random(seed);run_three();
        end
        if(cases!=786 || a_cases!=262 || b_cases!=262 || q_cases!=262 || pause_cycles!=617272)
            $fatal(1,"coverage mismatch cases=%0d pauses=%0d",cases,pause_cycles);
        $display("SOLVE_PIPELINE_TEST PASS cases=%0d a=%0d b=%0d q=%0d ce_pause_cycles=%0d source_mutation_checks=786",
            cases,a_cases,b_cases,q_cases,pause_cycles);
        $finish;
    end
    initial begin #20_000_000;$fatal(1,"solve pipeline test timed out");end
endmodule
