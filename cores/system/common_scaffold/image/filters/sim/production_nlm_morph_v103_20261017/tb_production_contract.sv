`timescale 1ns/1ps

// Production-source behavioral boundary checks. This intentionally observes
// only the production engine's documented ports plus its stable state register
// for CE/reset holding; it does not depend on the v103 candidate's pipelined
// multiplier/divider states.
module tb_production_contract #(parameter PIXEL_W_MAX=12);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;

    // PIXEL_W=1 remains a supported configuration and exercises a real frame.
    reg p1_cmd_valid=0,p1_s_valid=0;
    reg [0:0] p1_s_data=0;
    wire p1_cmd_ready,p1_s_ready,p1_rsp_valid,p1_m_valid,p1_m_sof,p1_m_eol;
    wire [0:0] p1_m_data;
    wire [7:0] p1_rsp_tag,p1_rsp_error;
    integer p1_outputs=0,p1_responses=0;
    img_filter_frame_engine #(.PIXEL_W(1),.MAX_WIDTH(1),.MAX_HEIGHT(1),.OP(0)) dut_p1(
        .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
        .cmd_valid(p1_cmd_valid),.cmd_ready(p1_cmd_ready),.cmd_tag(8'h11),
        .cfg_width(16'd1),.cfg_height(16'd1),.cfg_structuring_element(9'b1),
        .cfg_patch_radius(8'd0),.cfg_search_radius(8'd0),.cfg_h_q8(16'd1),
        .rsp_valid(p1_rsp_valid),.rsp_ready(1'b1),.rsp_tag(p1_rsp_tag),.rsp_error(p1_rsp_error),
        .s_data(p1_s_data),.s_valid(p1_s_valid),.s_sof(1'b1),.s_eol(1'b1),.s_ready(p1_s_ready),
        .m_data(p1_m_data),.m_valid(p1_m_valid),.m_sof(p1_m_sof),.m_eol(p1_m_eol),.m_ready(1'b1)
    );

    // PIXEL_W=16 follows the configured production width boundary.
    reg p16_cmd_valid=0,p16_s_valid=0;
    reg [15:0] p16_s_data=16'd7;
    wire p16_cmd_ready,p16_rsp_valid,p16_s_ready;
    wire [7:0] p16_rsp_tag,p16_rsp_error;
    wire [15:0] p16_m_data;
    wire p16_m_valid,p16_m_sof,p16_m_eol;
    integer p16_outputs=0;
    img_filter_frame_engine #(.PIXEL_W(16),.MAX_WIDTH(1),.MAX_HEIGHT(1),.OP(0)) dut_p16(
        .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
        .cmd_valid(p16_cmd_valid),.cmd_ready(p16_cmd_ready),.cmd_tag(8'h16),
        .cfg_width(16'd1),.cfg_height(16'd1),.cfg_structuring_element(9'b1),
        .cfg_patch_radius(8'd0),.cfg_search_radius(8'd0),.cfg_h_q8(24'd1),
        .rsp_valid(p16_rsp_valid),.rsp_ready(1'b1),.rsp_tag(p16_rsp_tag),.rsp_error(p16_rsp_error),
        .s_data(p16_s_data),.s_valid(p16_s_valid),.s_sof(1'b1),.s_eol(1'b1),.s_ready(p16_s_ready),
        .m_data(p16_m_data),.m_valid(p16_m_valid),.m_sof(p16_m_sof),.m_eol(p16_m_eol),.m_ready(1'b1)
    );

    // Production NLM has a combined combinational multiply/divide path rather
    // than the candidate's NCMUL_WAIT/DIV_MID states. Verify CE hold while the
    // production controller is in NWEIGHT, asynchronous reset, and clean replay.
    reg nlm_clk_en=1,nlm_cmd_valid=0,nlm_s_valid=0;
    reg [7:0] nlm_s_data=0;
    reg [1:0] nlm_sent=0;
    wire nlm_cmd_ready,nlm_s_ready,nlm_rsp_valid,nlm_m_valid,nlm_m_sof,nlm_m_eol;
    wire [7:0] nlm_m_data,nlm_rsp_tag,nlm_rsp_error;
    integer nlm_outputs=0,nlm_responses=0;
    img_filter_frame_engine #(.PIXEL_W(8),.MAX_WIDTH(2),.MAX_HEIGHT(2),.OP(2)) dut_nlm(
        .clk(clk),.rst_n(rst_n),.clk_en(nlm_clk_en),
        .cmd_valid(nlm_cmd_valid),.cmd_ready(nlm_cmd_ready),.cmd_tag(8'h2a),
        .cfg_width(16'd2),.cfg_height(16'd2),.cfg_structuring_element(9'd0),
        .cfg_patch_radius(8'd1),.cfg_search_radius(8'd1),.cfg_h_q8(16'd7680),
        .rsp_valid(nlm_rsp_valid),.rsp_ready(1'b1),.rsp_tag(nlm_rsp_tag),.rsp_error(nlm_rsp_error),
        .s_data(nlm_s_data),.s_valid(nlm_s_valid),.s_sof(nlm_sent==0),.s_eol(nlm_sent[0]),.s_ready(nlm_s_ready),
        .m_data(nlm_m_data),.m_valid(nlm_m_valid),.m_sof(nlm_m_sof),.m_eol(nlm_m_eol),.m_ready(1'b1)
    );

    always @(posedge clk) if (rst_n) begin
        if (p1_m_valid) begin
            if (p1_m_data!==1'b1 || p1_m_sof!==1'b1 || p1_m_eol!==1'b1)
                $fatal(1,"PIXEL_W=1 output contract");
            p1_outputs=p1_outputs+1;
        end
        if (p1_rsp_valid) begin
            if (p1_rsp_error!==0 || p1_rsp_tag!==8'h11) $fatal(1,"PIXEL_W=1 response");
            p1_responses=p1_responses+1;
        end
        if (p16_m_valid) begin
            if (PIXEL_W_MAX < 16 || p16_m_data!==16'd7 ||
                p16_m_sof!==1'b1 || p16_m_eol!==1'b1)
                $fatal(1,"PIXEL_W=16 output contract");
            p16_outputs=p16_outputs+1;
        end
        if (nlm_m_valid) begin
            if (nlm_m_sof!==(nlm_outputs%4==0) || nlm_m_eol!==(nlm_outputs%2==1))
                $fatal(1,"NLM output markers index=%0d",nlm_outputs);
            nlm_outputs=nlm_outputs+1;
        end
        if (nlm_rsp_valid) begin
            if (nlm_rsp_error!==0 || nlm_rsp_tag!==8'h2a) $fatal(1,"NLM response");
            nlm_responses=nlm_responses+1;
        end
    end

    task start_nlm;
        integer i;
        begin
            @(negedge clk);nlm_cmd_valid=1;
            do @(posedge clk); while(!nlm_cmd_ready);
            @(negedge clk);nlm_cmd_valid=0;
            for(i=0;i<4;i=i+1) begin
                @(negedge clk);
                nlm_s_valid=1;
                case(i)
                  0:nlm_s_data=8'd20;
                  1:nlm_s_data=8'd60;
                  2:nlm_s_data=8'd100;
                  default:nlm_s_data=8'd140;
                endcase
                nlm_sent=i;
                do @(posedge clk); while(!nlm_s_ready);
            end
            @(negedge clk);nlm_s_valid=0;
        end
    endtask

    integer held_state;
    reg [63:0] held_ssd,held_weighted_sum,held_weight_sum;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;

        @(negedge clk);p1_cmd_valid=1;
        do @(posedge clk); while(!p1_cmd_ready);
        @(negedge clk);p1_cmd_valid=0;p1_s_valid=1;p1_s_data=1'b1;
        do @(posedge clk); while(!p1_s_ready);
        @(negedge clk);p1_s_valid=0;
        wait(p1_responses==1);
        if(p1_outputs!=1) $fatal(1,"PIXEL_W=1 output count=%0d",p1_outputs);
        $display("PASS production PIXEL_W=1 supported");

        @(negedge clk);p16_cmd_valid=1;
        do @(posedge clk); while(!p16_cmd_ready);
        @(negedge clk);p16_cmd_valid=0;
        if (PIXEL_W_MAX < 16) begin
            wait(p16_rsp_valid);
            if(p16_rsp_error!==8'd1 || p16_rsp_tag!==8'h16 || p16_s_ready!==1'b0)
                $fatal(1,"PIXEL_W=16 must return error=1 without accepting pixels");
            @(posedge clk);
            $display("PASS production PIXEL_W=16 rejected");
        end else begin
            @(negedge clk);p16_s_valid=1;
            do @(posedge clk); while(!p16_s_ready);
            @(negedge clk);p16_s_valid=0;
            wait(p16_rsp_valid);
            if(p16_rsp_error!==8'd0 || p16_rsp_tag!==8'h16)
                $fatal(1,"PIXEL_W=16 supported configuration response");
            @(posedge clk);#1;
            if(p16_outputs!=1) $fatal(1,"PIXEL_W=16 output count=%0d",p16_outputs);
            $display("PASS production PIXEL_W=16 supported");
        end

        nlm_outputs=0;nlm_responses=0;nlm_sent=0;
        start_nlm();
        wait(dut_nlm.state==dut_nlm.NWEIGHT);
        @(negedge clk);
        nlm_clk_en=0;
        held_state=dut_nlm.state;
        held_ssd=dut_nlm.ssd;
        held_weighted_sum=dut_nlm.weighted_sum;
        held_weight_sum=dut_nlm.weight_sum;
        repeat(3) begin
            @(posedge clk);#1;
            if(dut_nlm.state!==held_state || dut_nlm.ssd!==held_ssd ||
               dut_nlm.weighted_sum!==held_weighted_sum || dut_nlm.weight_sum!==held_weight_sum)
                $fatal(1,"production NWEIGHT did not hold under clk_en=0");
        end
        // Asynchronous reset while the NLM arithmetic phase is held.
        @(negedge clk);rst_n=0;#1;
        if(dut_nlm.state!==dut_nlm.IDLE || nlm_rsp_valid || nlm_m_valid)
            $fatal(1,"asynchronous reset did not abort NLM state/output");
        repeat(2) @(posedge clk);
        @(negedge clk);nlm_clk_en=1;rst_n=1;nlm_outputs=0;nlm_responses=0;nlm_sent=0;
        start_nlm();
        wait(nlm_responses==1);
        if(nlm_outputs!=4) $fatal(1,"NLM replay outputs=%0d expected=4",nlm_outputs);
        $display("PASS production NLM CE-hold async-reset replay outputs=4");
        $display("PASS PRODUCTION CONTRACT PIXEL_W=1,16 NLM=CE+RESET");
        $finish;
    end

    initial begin #20000000;$fatal(1,"production contract timeout");end
endmodule
