`timescale 1ns/1ps
// Independent Python-integer vectors + byte-for-byte v95 reference RTL.
// Payload equivalence is required; completion cycles intentionally differ.
module tb_awb_autogain_div3_compare;
parameter WIDTH=48;
parameter VECTORS=1;
localparam VW=3*WIDTH+185;
localparam TARGET_DIGITS=(WIDTH+3)/2;
localparam EXPECTED_SAVING=WIDTH+10-TARGET_DIGITS;
reg clk=0;
always #5 clk=~clk;
reg rst_n=0,ce=1,stats_valid=0,gain_ready=0;
reg [WIDTH-1:0] sum_r=0,sum_g=0,sum_b=0;
reg [31:0] pixel_count=0,frame_id=0;
reg overflow=0;
reg [15:0] minimum=0,maximum=1024;
wire c_ready,r_ready,c_valid,r_valid;
wire [15:0] c_r,c_g,c_b,r_r,r_g,r_b;
wire [31:0] c_frame,r_frame;
wire [7:0] c_error,r_error;
wire [87:0] c_payload={c_error,c_frame,c_b,c_g,c_r};
wire [87:0] r_payload={r_error,r_frame,r_b,r_g,r_r};
reg [VW-1:0] vectors[0:VECTORS-1];
reg [87:0] expected;
reg [15:0] exp_r,exp_g,exp_b;
reg [31:0] exp_frame;
reg [7:0] exp_error;
string vector_path;
integer i,wall,ce_edges,c_latency,r_latency,checks=0;
integer c_min=1000000,c_max=0,r_min=1000000,r_max=0,c_sum=0,r_sum=0;
integer ce_freezes=0,poison_cycles=0,reset_cancellations=0;
integer async_reset_ce0_cancellations=0;
integer pause_sum=0,pause_target=0,pause_divide=0;
reg c_seen,r_seen;
reg held_ce,held_cv,held_rv,held_ready;
reg [87:0] held_cp,held_rp;
reg [2047:0] held_c_state,held_r_state;
wire [2047:0] c_snapshot={candidate.state,candidate.channel,candidate.sums[0],
    candidate.sums[1],candidate.sums[2],candidate.total_padded,candidate.target,
    candidate.minimum,candidate.maximum,candidate.sum_carry,candidate.sum_byte_index,
    c_valid,c_payload,candidate.u_target_div3.busy,candidate.u_target_div3.result_valid,
    candidate.u_target_div3.quotient_out,candidate.u_target_div3.remainder_out,
    candidate.u_target_div3.input_shift,candidate.u_target_div3.digits_left,
    candidate.u_divider.state,candidate.u_divider.busy,candidate.u_divider.done,
    candidate.u_divider.quotient_out,candidate.u_divider.remainder_out,
    candidate.u_divider.divide_by_zero,candidate.u_divider.numerator_q,
    candidate.u_divider.quotient_q,candidate.u_divider.denominator_q,
    candidate.u_divider.trial_q,candidate.u_divider.remainder_q,
    candidate.u_divider.candidate_q,candidate.u_divider.bit_index,
    candidate.u_divider.group_index,candidate.u_divider.active_groups,
    candidate.u_divider.borrow_q};
wire [2047:0] r_snapshot={reference.state,reference.channel,reference.sums[0],
    reference.sums[1],reference.sums[2],reference.total_padded,reference.target,
    reference.minimum,reference.maximum,reference.sum_carry,reference.sum_byte_index,
    r_valid,r_payload,reference.u_divider.state,reference.u_divider.busy,
    reference.u_divider.done,reference.u_divider.quotient_out,
    reference.u_divider.remainder_out,reference.u_divider.divide_by_zero,
    reference.u_divider.numerator_q,reference.u_divider.quotient_q,
    reference.u_divider.denominator_q,reference.u_divider.trial_q,
    reference.u_divider.remainder_q,reference.u_divider.candidate_q,
    reference.u_divider.bit_index,reference.u_divider.group_index,
    reference.u_divider.active_groups,reference.u_divider.borrow_q};

img_isp_awb_autogain_div3_candidate #(.SUM_WIDTH(WIDTH)) candidate(
    .clk(clk),.rst_n(rst_n),.clk_en(ce),.stats_valid(stats_valid),.stats_ready(c_ready),
    .stats_sum_r(sum_r),.stats_sum_g(sum_g),.stats_sum_b(sum_b),
    .stats_pixel_count(pixel_count),.stats_frame_id(frame_id),.stats_overflow(overflow),
    .cfg_min_gain(minimum),.cfg_max_gain(maximum),.gain_valid(c_valid),.gain_ready(gain_ready),
    .gain_r(c_r),.gain_g(c_g),.gain_b(c_b),.gain_frame_id(c_frame),.gain_error(c_error));
ref_img_isp_awb_autogain #(.SUM_WIDTH(WIDTH)) reference(
    .clk(clk),.rst_n(rst_n),.clk_en(ce),.stats_valid(stats_valid),.stats_ready(r_ready),
    .stats_sum_r(sum_r),.stats_sum_g(sum_g),.stats_sum_b(sum_b),
    .stats_pixel_count(pixel_count),.stats_frame_id(frame_id),.stats_overflow(overflow),
    .cfg_min_gain(minimum),.cfg_max_gain(maximum),.gain_valid(r_valid),.gain_ready(gain_ready),
    .gain_r(r_r),.gain_g(r_g),.gain_b(r_b),.gain_frame_id(r_frame),.gain_error(r_error));

always @(posedge clk) begin
    if(rst_n) begin
        held_ce=ce;held_cv=c_valid;held_rv=r_valid;held_ready=gain_ready;
        held_cp=c_payload;held_rp=r_payload;held_c_state=c_snapshot;held_r_state=r_snapshot;
        if(!ce) begin
            if(candidate.state==candidate.SUM_TOTAL) pause_sum=pause_sum+1;
            if(candidate.state==candidate.DIV_TARGET) pause_target=pause_target+1;
            if(candidate.state==candidate.DIVIDE) pause_divide=pause_divide+1;
        end
        if(ce && stats_valid && (!c_ready || !r_ready)) poison_cycles=poison_cycles+1;
        #1;
        if(rst_n && !held_ce) begin
            ce_freezes=ce_freezes+1;
            if(c_snapshot!==held_c_state || r_snapshot!==held_r_state || c_ready || r_ready)
                $fatal(1,"AUTOGAIN CE register freeze failed WIDTH=%0d",WIDTH);
        end
        if(rst_n && held_cv && (!held_ce || !held_ready) &&
            (!c_valid || c_payload!==held_cp)) $fatal(1,"candidate elastic output changed");
        if(rst_n && held_rv && (!held_ce || !held_ready) &&
            (!r_valid || r_payload!==held_rp)) $fatal(1,"reference elastic output changed");
    end
end

task reset_solvers;
    input integer reset_ce;
    begin
        @(negedge clk);ce=reset_ce;rst_n=0;stats_valid=0;gain_ready=0;
        #1;
        if(c_valid || r_valid || c_ready || r_ready) $fatal(1,"autogain reset boundary failed");
        if(c_payload!=={8'd0,32'd0,16'd256,16'd256,16'd256} || c_payload!==r_payload)
            $fatal(1,"autogain asynchronous reset payload failed");
        repeat(2) @(posedge clk);
        @(negedge clk);rst_n=1;
        if(!reset_ce) begin
            async_reset_ce0_cancellations=async_reset_ce0_cancellations+1;
            repeat(2) begin @(posedge clk);#2;
                if(c_valid || r_valid || c_ready || r_ready)
                    $fatal(1,"autogain CE=0 reset release failed");
            end
            @(negedge clk);ce=1;
        end
        #1;if(!c_ready || !r_ready) $fatal(1,"autogain ready after reset failed");
    end
endtask

task load_vector;
    input integer index;
    begin
        {exp_error,exp_frame,exp_b,exp_g,exp_r,maximum,minimum,overflow,
         frame_id,pixel_count,sum_b,sum_g,sum_r}=vectors[index];
        expected={exp_error,exp_frame,exp_b,exp_g,exp_r};
    end
endtask

task observe_results;
    begin
        if(c_valid) begin
            if(c_payload!==expected) $fatal(1,"candidate integer-reference mismatch WIDTH=%0d case=%0d got=%h expected=%h",WIDTH,i,c_payload,expected);
            if(!c_seen) begin c_seen=1;c_latency=ce_edges;end
        end
        if(r_valid) begin
            if(r_payload!==expected) $fatal(1,"v95 integer-reference mismatch WIDTH=%0d case=%0d got=%h expected=%h",WIDTH,i,r_payload,expected);
            if(!r_seen) begin r_seen=1;r_latency=ce_edges;end
        end
    end
endtask

task run_vector;
    input integer index;
    reg metadata_error;
    begin
        @(negedge clk);ce=1;gain_ready=0;
        #1;if(!c_ready || !r_ready) $fatal(1,"autogain inputs not ready case=%0d",index);
        load_vector(index);stats_valid=1;
        metadata_error=(pixel_count==0 || overflow || minimum>maximum);
        if(index==0) begin
            ce=0;
            repeat(3) begin @(posedge clk);#2;
                if(c_ready || r_ready || c_valid || r_valid) $fatal(1,"autogain accepted while CE=0");
            end
            @(negedge clk);ce=1;
        end
        @(posedge clk);#2;
        ce_edges=1;c_seen=0;r_seen=0;c_latency=0;r_latency=0;
        observe_results();
        @(negedge clk);
        // Keep VALID high with poisoned live data until both outputs finish.
        // Readiness must stay low, so these starts cannot replace the snapshot.
        sum_r={WIDTH{1'b1}};sum_g=0;sum_b=1;
        pixel_count=0;frame_id=32'hdeadbeef;overflow=1;minimum=65535;maximum=0;
        wall=0;
        while(!c_seen || !r_seen) begin
            ce=((wall%11)!=0 && (wall%11)!=3);
            #1;if(c_ready || r_ready) $fatal(1,"autogain accepted busy/pending poison");
            @(posedge clk);#2;
            if(ce) ce_edges=ce_edges+1;
            observe_results();
            wall=wall+1;
            if(wall>1600) $fatal(1,"autogain timeout WIDTH=%0d case=%0d",WIDTH,index);
            @(negedge clk);
        end
        if(c_payload!==r_payload || !c_valid || !r_valid) $fatal(1,"autogain final pair mismatch");
        if((metadata_error && c_latency!=r_latency) ||
            (!metadata_error && r_latency-c_latency!=EXPECTED_SAVING))
            $fatal(1,"autogain unexpected CE latency delta WIDTH=%0d case=%0d candidate=%0d ref=%0d expected_delta=%0d",WIDTH,index,c_latency,r_latency,metadata_error?0:EXPECTED_SAVING);
        if(WIDTH<=49 && (c_latency>=800 || r_latency>=800))
            $fatal(1,"autogain original <800 CE watchdog bound exceeded");
        if(c_latency<c_min)c_min=c_latency;if(c_latency>c_max)c_max=c_latency;
        if(r_latency<r_min)r_min=r_latency;if(r_latency>r_max)r_max=r_latency;
        c_sum=c_sum+c_latency;r_sum=r_sum+r_latency;checks=checks+1;
        $display("AWB_DIV3_CASE WIDTH=%0d case=%0d candidate_ce=%0d v95_ce=%0d saved_ce=%0d metadata_error=%0d",WIDTH,index,c_latency,r_latency,r_latency-c_latency,metadata_error);
        stats_valid=0;ce=0;gain_ready=1;
        repeat(2) begin @(posedge clk);#2;
            if(!c_valid || !r_valid || c_payload!==expected || r_payload!==expected)
                $fatal(1,"autogain CE-disabled result retirement");
        end
        @(negedge clk);ce=1;gain_ready=0;
        repeat(3) begin @(posedge clk);#2;
            if(!c_valid || !r_valid || c_payload!==expected || r_payload!==expected)
                $fatal(1,"autogain result backpressure failed");
        end
        @(negedge clk);gain_ready=1;
        @(posedge clk);#2;
        if(c_valid || r_valid || !c_ready || !r_ready) $fatal(1,"autogain result retirement failed");
        @(negedge clk);gain_ready=0;
    end
endtask

task cancel_in_phase;
    input integer phase;
    begin
        @(negedge clk);ce=1;gain_ready=0;
        sum_r={WIDTH{1'b1}};sum_g={WIDTH{1'b1}};sum_b={WIDTH{1'b1}};
        pixel_count=1;frame_id=32'h12345678;overflow=0;minimum=0;maximum=1024;stats_valid=1;
        @(posedge clk);#2;
        @(negedge clk);stats_valid=0;wall=0;
        while((phase==0 && !candidate.u_target_div3.busy) ||
              (phase==1 && !candidate.u_divider.busy) ||
              (phase==2 && (!c_valid || !r_valid))) begin
            @(posedge clk);#2;wall=wall+1;
            if(wall>800) $fatal(1,"autogain reset phase unreachable");
        end
        reset_solvers(0);reset_cancellations=reset_cancellations+1;
        repeat(20) begin @(posedge clk);#2;
            if(c_valid || r_valid || !c_ready || !r_ready) $fatal(1,"autogain reset ghost output");
        end
    end
endtask

initial begin
    if(!$value$plusargs("VECTORS_FILE=%s",vector_path)) $fatal(1,"missing vector file");
    $readmemh(vector_path,vectors);
    reset_solvers(1);
    for(i=0;i<VECTORS;i=i+1) run_vector(i);
    cancel_in_phase(0);cancel_in_phase(1);cancel_in_phase(2);
    i=0;run_vector(0);
    if(!ce_freezes || !poison_cycles || !pause_sum || !pause_target || !pause_divide)
        $fatal(1,"autogain CE/poison coverage missing");
    $display("AWB_DIV3_COMPARE_PASS WIDTH=%0d vectors=%0d checked=%0d c_min=%0d c_max=%0d c_sum=%0d v95_min=%0d v95_max=%0d v95_sum=%0d ce_freezes=%0d poison_cycles=%0d pause_sum=%0d pause_target=%0d pause_divide=%0d reset_cancellations=%0d async_reset_ce0_cancellations=%0d",WIDTH,VECTORS,checks,c_min,c_max,c_sum,r_min,r_max,r_sum,ce_freezes,poison_cycles,pause_sum,pause_target,pause_divide,reset_cancellations,async_reset_ce0_cancellations);
    $finish;
end
initial begin #100000000;$fatal(1,"autogain comparison wall timeout");end
endmodule
