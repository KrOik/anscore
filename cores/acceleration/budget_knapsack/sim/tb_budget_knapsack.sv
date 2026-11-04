`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module tb;
parameter MAX_ITEMS=16,MAX_CAPACITY=63,COST_W=8,VALUE_W=16,TAG_W=8;
parameter INPUTS=1,OUTPUTS=1,FRAMES=1;
localparam INDEX_W=(MAX_ITEMS>1)?$clog2(MAX_ITEMS):1;
localparam COUNT_W=$clog2(MAX_ITEMS+1);
localparam BUDGET_W=(MAX_CAPACITY>0)?$clog2(MAX_CAPACITY+1):1;
localparam SUM_W=VALUE_W+((MAX_ITEMS>1)?$clog2(MAX_ITEMS):0);
localparam IN_W=TAG_W+32+2+VALUE_W+COST_W;
localparam OUT_W=TAG_W+32+2+BUDGET_W+SUM_W+COUNT_W+4+INDEX_W+VALUE_W+COST_W;
reg clk=0;always #5 clk=~clk;
reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
reg [COST_W-1:0] s_cost=0;reg [VALUE_W-1:0] s_value=0;
reg [31:0] s_capacity=0;reg [TAG_W-1:0] s_tag=0;
wire s_ready,m_valid,m_keep,m_selected,m_first,m_last;
wire [INDEX_W-1:0] m_index;wire [COST_W-1:0] m_cost;wire [VALUE_W-1:0] m_value;
wire [COUNT_W-1:0] m_count;wire [SUM_W-1:0] m_total_value;wire [BUDGET_W-1:0] m_total_cost;
wire [1:0] m_error;wire [31:0] m_capacity;wire [TAG_W-1:0] m_tag;
budget_knapsack #(.MAX_ITEMS(MAX_ITEMS),.MAX_CAPACITY(MAX_CAPACITY),.COST_W(COST_W),
    .VALUE_W(VALUE_W),.TAG_W(TAG_W)) dut(.*);
reg [IN_W-1:0] stimuli[0:INPUTS-1];reg [OUT_W-1:0] golden[0:OUTPUTS-1];
reg [31:0] latencies[0:FRAMES-1];
wire [IN_W-1:0] source_payload={s_tag,s_capacity,s_last,s_keep,s_value,s_cost};
wire [OUT_W-1:0] payload={m_tag,m_capacity,m_error,m_total_cost,m_total_value,m_count,
    m_last,m_first,m_keep,m_selected,m_index,m_value,m_cost};
reg checking=0,held_output=0,held_source=0,awaiting_first=0;
reg [OUT_W-1:0] output_before;reg [IN_W-1:0] source_before;
integer cycles=0,sent=0,received=0,tails=0,tail_cycle=0,expected_latency=0;
integer output_stalls=0,source_stalls=0,reset_probes=0,waited;

always @(posedge clk) begin
    cycles=cycles+1;
    if(checking && !rst) begin
        if(held_output && (!m_valid || payload!==output_before)) $fatal(1,"held output changed");
        if(held_source && (!s_valid || source_payload!==source_before)) $fatal(1,"source driver changed blocked token");
        held_output=m_valid&&!m_ready;output_before=payload;
        held_source=s_valid&&!s_ready;source_before=source_payload;
        if(s_valid&&!s_ready) source_stalls=source_stalls+1;
        if(m_valid&&!m_ready) output_stalls=output_stalls+1;
        if(s_valid&&s_ready) begin
            sent=sent+1;
            if(s_last) begin
                if(tails>=FRAMES || awaiting_first) $fatal(1,"tail/result overlap");
                tail_cycle=cycles;expected_latency=latencies[tails];tails=tails+1;awaiting_first=1;
            end
        end
        if(m_valid&&m_ready) begin
            if(received>=OUTPUTS || payload!==golden[received])
                $fatal(1,"output %0d got=%h expected=%h",received,payload,golden[received]);
            received=received+1;
        end
    end
    #1;
    if(checking && !rst && awaiting_first && m_valid) begin
        if(cycles-tail_cycle!=expected_latency)
            $fatal(1,"first valid latency got=%0d expected=%0d",cycles-tail_cycle,expected_latency);
        awaiting_first=0;
    end
end

task reset_now;
begin
    rst=1;s_valid=0;m_ready=0;
    repeat(2) @(posedge clk);
    @(negedge clk);rst=0;#1;
    if(!s_ready || m_valid || m_total_value!=0 || m_total_cost!=0 || m_error!=0)
        $fatal(1,"reset did not rearm/clear");
end endtask

task reset_core;
begin @(negedge clk);reset_now();end endtask

task probe(input keep,input tail);
begin
    @(negedge clk);s_valid=1;s_keep=keep;s_last=tail;s_cost=0;s_value=1;s_capacity=0;s_tag=0;
    @(posedge clk);if(!s_ready) $fatal(1,"probe not accepted");
    @(negedge clk);s_valid=0;
end endtask

task abort_at(input integer target);
begin
    reset_core();
    if(target==dut.STATUS_HOLD) probe(0,1);
    else probe(1,target!=dut.COLLECT);
    if(target==dut.OUTPUT_HOLD) begin s_valid=1;s_keep=0;s_last=1;s_capacity=0;end
    waited=0;
    while(dut.state!=target && waited<100) begin @(negedge clk);waited=waited+1;end
    if(dut.state!=target) $fatal(1,"phase reset target missing %0d",target);
    // Assert at the same observed boundary; no intervening active clock.
    reset_now();reset_probes=reset_probes+1;
end endtask

initial begin
    $readmemh("input.hex",stimuli);$readmemh("golden.hex",golden);$readmemh("latency.hex",latencies);
    abort_at(dut.COLLECT);abort_at(dut.INITIALIZE);abort_at(dut.ITEM_READ);abort_at(dut.ITEM_SETUP);
    abort_at(dut.CURRENT_READ);abort_at(dut.BASE_READ);abort_at(dut.UPDATE);
    abort_at(dut.FINAL_READ);abort_at(dut.FINALIZE);abort_at(dut.OUTPUT_READ);
    abort_at(dut.OUTPUT_HOLD);abort_at(dut.STATUS_HOLD);
    @(negedge clk);checking=1;
    fork
        begin : input_driver
            integer beat;
            // A zero-gap next token is offered at the preceding token's return boundary.
            for(beat=0;beat<INPUTS;beat=beat+1) begin
                if(beat%7==2) repeat(2) @(negedge clk);
                s_valid=1;{s_tag,s_capacity,s_last,s_keep,s_value,s_cost}=stimuli[beat];
                do @(posedge clk);while(!s_ready);
                @(negedge clk);s_valid=0;
            end
        end
        begin : output_driver
            integer token;
            reg [OUT_W-1:0] captured;
            for(token=0;token<OUTPUTS;token=token+1) begin
                while(!m_valid) @(negedge clk);
                captured=payload;
                repeat(3) begin @(posedge clk);#1;if(!m_valid || payload!==captured) $fatal(1,"forced hold failed");end
                @(negedge clk);m_ready=1;
                @(posedge clk);
                @(negedge clk);m_ready=0;
            end
        end
    join
    repeat(8) @(negedge clk);
    if(sent!=INPUTS || received!=OUTPUTS || tails!=FRAMES || awaiting_first || m_valid || !s_ready)
        $fatal(1,"incomplete or extra transaction");
    if(source_stalls==0 || output_stalls<3*OUTPUTS || reset_probes!=12) $fatal(1,"coverage missing");
    $display("PASS knapsack M=%0d C=%0d W=%0d V=%0d T=%0d frames=%0d outputs=%0d source_stalls=%0d output_stalls=%0d reset_probes=%0d",
        MAX_ITEMS,MAX_CAPACITY,COST_W,VALUE_W,TAG_W,FRAMES,received,source_stalls,output_stalls,reset_probes);
    $finish;
end
initial begin #100000000;$fatal(1,"watchdog");end
endmodule
