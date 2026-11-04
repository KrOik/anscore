// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ordered_completion_buffer;
    parameter DEPTH=8,DATA_W=32,META_W=16;
    localparam TAG_W=(DEPTH<2)?1:$clog2(DEPTH),COUNT_W=$clog2(DEPTH+1);
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg a_valid=0,c_valid=0,m_ready=0,c_error=0;
    reg [META_W-1:0] a_meta=0;
    reg [TAG_W-1:0] c_tag=0;
    reg [DATA_W-1:0] c_data=0;
    wire a_ready,c_ready,c_rejected,m_valid,m_error;
    wire [TAG_W-1:0] a_tag;
    wire [META_W-1:0] m_meta;
    wire [DATA_W-1:0] m_data;
    wire [COUNT_W-1:0] occupancy;
    ordered_completion_buffer #(.DEPTH(DEPTH),.DATA_W(DATA_W),.META_W(META_W)) dut(.*);

    // Independent issue-order list. Physical tags are observed from allocation
    // handshakes, not predicted from DUT pointers or read through hierarchy.
    reg [TAG_W-1:0] q_tag[0:2047];
    reg [META_W-1:0] q_meta[0:2047];
    reg [DATA_W-1:0] q_data[0:2047];
    reg q_error[0:2047],q_done[0:2047];
    integer wr=0,rd=0,cycle=0,allocated_total=0,retired_total=0,rejected_total=0;
    integer simultaneous=0,full_blocks=0,held_outputs=0,accepted_completions=0;
    integer found,k;
    reg expected_rejected,allocation_taken=0,was_stalled=0;
    reg [META_W+DATA_W:0] held_payload;
    always @(posedge clk) begin
        cycle=cycle+1;
        if(cycle>20000) $fatal(1,"watchdog");
        if(rst) begin
            wr=0;rd=0;allocation_taken=0;was_stalled=0;
            #1;
            if(m_valid || a_ready || c_ready || occupancy!==0 || c_rejected)
                $fatal(1,"reset contract");
        end else begin
            if(occupancy!==(COUNT_W'(wr-rd))) $fatal(1,"occupancy mismatch");
            if(c_ready!==1) $fatal(1,"completion interface unexpectedly blocked");
            if(was_stalled && (!m_valid || {m_meta,m_data,m_error}!==held_payload))
                $fatal(1,"output changed under backpressure");
            if(m_valid) begin
                if(rd>=wr || !q_done[rd]) $fatal(1,"premature output");
                if({m_meta,m_data,m_error}!=={q_meta[rd],q_data[rd],q_error[rd]})
                    $fatal(1,"out-of-order/incorrect output at entry %0d",rd);
            end
            was_stalled=m_valid&&!m_ready;
            held_payload={m_meta,m_data,m_error};
            if(was_stalled) held_outputs=held_outputs+1;
            if(a_valid&&!a_ready) full_blocks=full_blocks+1;
            if(a_valid&&a_ready&&m_valid&&m_ready) simultaneous=simultaneous+1;
            if(m_valid&&m_ready) begin rd=rd+1;retired_total=retired_total+1;end
            expected_rejected=0;
            if(c_valid&&c_ready) begin
                found=-1;
                for(k=rd;k<wr;k=k+1) if(q_tag[k]==c_tag) found=k;
                if(found<0 || q_done[found]) begin
                    expected_rejected=1;rejected_total=rejected_total+1;
                end else begin
                    q_done[found]=1;q_data[found]=c_data;q_error[found]=c_error;
                    accepted_completions=accepted_completions+1;
                end
            end
            allocation_taken=a_valid&&a_ready;
            if(allocation_taken) begin
                if(wr-rd>=DEPTH || a_tag>=DEPTH || wr>=2048) $fatal(1,"bad allocation");
                for(k=rd;k<wr;k=k+1) if(q_tag[k]==a_tag) $fatal(1,"duplicate live tag");
                q_tag[wr]=a_tag;q_meta[wr]=a_meta;q_done[wr]=0;
                wr=wr+1;allocated_total=allocated_total+1;
            end
            #1;
            if(c_rejected!==expected_rejected) $fatal(1,"completion rejection mismatch");
        end
    end

    task reset_buffer;
        begin
            @(negedge clk);rst=1;a_valid=0;c_valid=0;m_ready=0;
            repeat(2) @(negedge clk);rst=0;
        end
    endtask
    task alloc(input integer meta,output reg [TAG_W-1:0] tag);
        begin
            @(negedge clk);a_meta=meta;a_valid=1;
            do @(posedge clk); while(!a_ready);
            tag=a_tag;
            @(negedge clk);a_valid=0;
        end
    endtask
    task completion(input [TAG_W-1:0] tag,input integer data,input bit error);
        begin
            @(negedge clk);c_valid=1;c_tag=tag;c_data=data;c_error=error;
            @(posedge clk);
            @(negedge clk);c_valid=0;
        end
    endtask
    task drain;
        integer remaining;
        begin
            @(negedge clk);a_valid=0;m_ready=1;c_valid=0;
            while(rd<wr) begin
                remaining=-1;
                for(integer j=rd;j<wr;j=j+1) if(!q_done[j]) remaining=j;
                if(remaining>=0) begin
                    c_valid=1;c_tag=q_tag[remaining];c_data=remaining*113+7;c_error=remaining%3==0;
                end else c_valid=0;
                @(negedge clk);
            end
            c_valid=0;
            repeat(4) @(negedge clk);
            if(m_valid || occupancy!==0) $fatal(1,"failed to empty");
        end
    endtask
    reg [TAG_W-1:0] tags[0:DEPTH-1],extra_tag;
    integer n,t,pick;
    initial begin
        reset_buffer();
        // Unallocated and encoded out-of-range tags must be consumed/rejected.
        completion(0,90,0);
        if((1<<TAG_W)>DEPTH) completion(TAG_W'(DEPTH),91,1);
        for(n=0;n<DEPTH;n=n+1) alloc(n+100,tags[n]);
        for(n=DEPTH-1;n>=0;n=n-1) completion(tags[n],n*19,n%2);
        completion(tags[DEPTH-1],999,1); // duplicate must not overwrite result
        fork
            alloc(900,extra_tag);
            begin repeat(5) @(negedge clk);m_ready=1;end
        join
        completion(extra_tag,1234,1);
        drain();

        // Completion for a newly allocated tag on the allocation edge is
        // rejected. A worker must return it on a later edge.
        @(negedge clk);a_valid=1;a_meta=901;c_valid=1;c_tag=a_tag;c_data=7;
        @(posedge clk);extra_tag=a_tag;
        @(negedge clk);a_valid=0;c_valid=0;
        completion(extra_tag,8,0);drain();

        // Deterministic interleaving uses only the observed issue-order list.
        // Offers remain stable while allocation is blocked by capacity.
        for(t=0;t<360;t=t+1) begin
            @(negedge clk);
            if(!a_valid || allocation_taken) begin
                a_valid=t%4!=0;a_meta=t*13+3;
            end
            m_ready=t%9>3;c_valid=0;
            if(rd<wr && t%5!=0) begin
                pick=(t%3==0)?rd:(wr-1);
                c_valid=1;c_tag=q_tag[pick];c_data=t*29+5;c_error=t%7==0;
            end
        end
        drain();

        // A reset cancels both a held completed head and unfinished followers.
        m_ready=0;
        for(n=0;n<DEPTH;n=n+1) alloc(n+800,tags[n]);
        completion(tags[0],555,0);
        wait(m_valid);repeat(4) @(negedge clk);
        reset_buffer();
        completion(tags[0],556,1);
        alloc(70,extra_tag);completion(extra_tag,71,0);drain();
        if(simultaneous<1 || full_blocks<4 || held_outputs<4 || rejected_total<4 ||
           allocated_total<20 || retired_total<15 || accepted_completions<15)
            $fatal(1,"coverage targets not reached");
        $display("PASS depth=%0d data=%0d meta=%0d allocated=%0d retired=%0d accepted_completions=%0d rejected=%0d full_wait=%0d simultaneous=%0d held=%0d",
            DEPTH,DATA_W,META_W,allocated_total,retired_total,accepted_completions,rejected_total,full_blocks,simultaneous,held_outputs);
        $finish;
    end
endmodule
