`timescale 1ns/1ps
module tb_awb_constant_div3_radix4;
parameter WIDTH=50;
parameter VECTORS=1;
localparam DIGITS=(WIDTH+1)/2;
localparam PAD_WIDTH=2*DIGITS;
localparam CW=(DIGITS<=1)?1:$clog2(DIGITS+1);
localparam SNAP_WIDTH=2+WIDTH+2+PAD_WIDTH+CW;
reg clk=0;
always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,result_ready=0;
reg [WIDTH-1:0] numerator=0;
wire start_ready,busy,result_valid;
wire [WIDTH-1:0] quotient;
wire [1:0] remainder;
reg [2*WIDTH+1:0] vectors[0:VECTORS-1];
string vector_path;
integer i,j,latency,wall,checks=0,ce_pause_edges=0;
integer busy_poison_edges=0,blocked_start_edges=0,reset_cancellations=0;
integer async_reset_ce0_cancellations=0;
reg [WIDTH-1:0] exp_q;
reg [1:0] exp_r;
reg previous_ce,previous_valid,previous_ready;
reg [SNAP_WIDTH-1:0] previous_state;
reg [WIDTH+1:0] previous_payload;
wire [SNAP_WIDTH-1:0] state_snapshot={busy,result_valid,quotient,remainder,
    dut.input_shift,dut.digits_left};

awb_constant_div3_radix4 #(.WIDTH(WIDTH)) dut(
    .clk(clk),.rst_n(rst_n),.clk_en(ce),.start(start),.start_ready(start_ready),
    .numerator_in(numerator),.busy(busy),.result_valid(result_valid),
    .result_ready(result_ready),.quotient_out(quotient),.remainder_out(remainder));

// Sample old controls before NBA, then inspect every architected/work register.
always @(posedge clk) begin
    if(rst_n) begin
        previous_ce=ce;previous_valid=result_valid;previous_ready=result_ready;
        previous_state=state_snapshot;previous_payload={quotient,remainder};
        if(ce && busy && start) busy_poison_edges=busy_poison_edges+1;
        if(ce && result_valid && !result_ready && start)
            blocked_start_edges=blocked_start_edges+1;
        #1;
        if(rst_n && !previous_ce) begin
            ce_pause_edges=ce_pause_edges+1;
            if(state_snapshot!==previous_state || start_ready)
                $fatal(1,"DIV3 CE freeze failed WIDTH=%0d",WIDTH);
        end
        if(rst_n && previous_valid && (!previous_ce || !previous_ready)) begin
            if(!result_valid || {quotient,remainder}!==previous_payload)
                $fatal(1,"DIV3 backpressure payload changed WIDTH=%0d",WIDTH);
        end
    end
end

task reset_unit;
    input integer reset_ce;
    begin
        @(negedge clk);ce=reset_ce;rst_n=0;start=0;result_ready=0;
        #1;
        if(busy || result_valid || start_ready || quotient!==0 || remainder!==0)
            $fatal(1,"DIV3 asynchronous reset failed");
        repeat(2) @(posedge clk);
        @(negedge clk);rst_n=1;
        if(!reset_ce) begin
            async_reset_ce0_cancellations=async_reset_ce0_cancellations+1;
            repeat(2) begin @(posedge clk);#2;
                if(busy || result_valid || start_ready || quotient!==0 || remainder!==0)
                    $fatal(1,"DIV3 CE=0 reset release failed");
            end
            @(negedge clk);ce=1;
        end
        #1;if(!start_ready) $fatal(1,"DIV3 reset did not restore ready");
    end
endtask

// Optional same-edge result retirement/start tests the elastic boundary.
task run_vector;
    input integer index;
    input integer retire_old;
    begin
        @(negedge clk);ce=1;result_ready=retire_old;
        numerator=vectors[index][2*WIDTH+1:WIDTH+2];
        exp_q=vectors[index][WIDTH+1:2];exp_r=vectors[index][1:0];start=1;
        #1;if(!start_ready) $fatal(1,"DIV3 input blocked case=%0d",index);
        @(posedge clk);#2;
        latency=1;
        if(!busy || result_valid) $fatal(1,"DIV3 request not captured");
        wall=0;
        while(!result_valid) begin
            @(negedge clk);
            // Assert a changing poison start during all work edges.
            numerator=~numerator;start=1;result_ready=0;
            ce=((wall%9)!=2 && (wall%9)!=3);
            if(busy && start_ready) $fatal(1,"DIV3 ready while busy");
            @(posedge clk);#2;
            if(ce) latency=latency+1;
            wall=wall+1;
            if(wall>4*DIGITS+20) $fatal(1,"DIV3 result timeout");
        end
        if(latency!=DIGITS+1)
            $fatal(1,"DIV3 latency WIDTH=%0d got=%0d expected=%0d",WIDTH,latency,DIGITS+1);
        if(quotient!==exp_q || remainder!==exp_r || remainder>2 || busy)
            $fatal(1,"DIV3 mismatch WIDTH=%0d case=%0d got=%h:%0d expected=%h:%0d",WIDTH,index,quotient,remainder,exp_q,exp_r);
        checks=checks+1;
        // A blocked result rejects fresh starts and holds despite CE stalls.
        for(j=0;j<4;j=j+1) begin
            @(negedge clk);ce=(j!=1);result_ready=0;start=1;numerator=~numerator;
            #1;if(start_ready) $fatal(1,"DIV3 ready with blocked result");
            @(posedge clk);#2;
            if(!result_valid || {quotient,remainder}!=={exp_q,exp_r})
                $fatal(1,"DIV3 blocked output mismatch");
        end
        // Even ready=1 cannot retire a result while CE is disabled.
        @(negedge clk);ce=0;result_ready=1;start=1;
        repeat(2) begin @(posedge clk);#2;
            if(!result_valid || start_ready) $fatal(1,"DIV3 CE-qualified retirement failed");
        end
        // Leave result pending. The next run retires and starts together.
        @(negedge clk);ce=1;result_ready=0;start=0;
    end
endtask

initial begin
    if(!$value$plusargs("VECTORS_FILE=%s",vector_path)) $fatal(1,"missing vector file");
    $readmemh(vector_path,vectors);
    reset_unit(1);
    // A CE-disabled request must remain unaccepted.
    @(negedge clk);ce=0;start=1;numerator={WIDTH{1'b1}};
    repeat(3) begin @(posedge clk);#2;
        if(busy || result_valid || start_ready) $fatal(1,"DIV3 accepted with CE=0");
    end
    @(negedge clk);ce=1;start=0;
    for(i=0;i<VECTORS;i=i+1) run_vector(i,i!=0);
    // Reset a pending result; no transaction may survive reset.
    reset_unit(0);reset_cancellations=reset_cancellations+1;
    @(negedge clk);numerator={WIDTH{1'b1}};start=1;
    @(posedge clk);#2;
    if(!busy) $fatal(1,"DIV3 cancellation request not busy");
    reset_unit(0);reset_cancellations=reset_cancellations+1;
    repeat(DIGITS+4) begin @(posedge clk);#2;
        if(busy || result_valid) $fatal(1,"DIV3 reset ghost result");
    end
    // Full-width run after cancellation verifies recovery as well as clear.
    run_vector(VECTORS-1,0);
    @(negedge clk);ce=1;start=0;result_ready=1;
    @(posedge clk);#2;
    if(result_valid || busy || !start_ready) $fatal(1,"DIV3 final retirement failed");
    if(!ce_pause_edges || !busy_poison_edges || !blocked_start_edges)
        $fatal(1,"DIV3 handshake coverage missing");
    $display("DIV3_RADIX4_PASS WIDTH=%0d vectors=%0d checked=%0d acceptance_inclusive_ce_latency=%0d ce_pause_edges=%0d busy_poison_edges=%0d blocked_start_edges=%0d reset_cancellations=%0d same_edge_retire_start=%0d async_reset_ce0_cancellations=%0d",WIDTH,VECTORS,checks,DIGITS+1,ce_pause_edges,busy_poison_edges,blocked_start_edges,reset_cancellations,VECTORS-1,async_reset_ce0_cancellations);
    $finish;
end
initial begin #100000000;$fatal(1,"DIV3 test wall timeout");end
endmodule
