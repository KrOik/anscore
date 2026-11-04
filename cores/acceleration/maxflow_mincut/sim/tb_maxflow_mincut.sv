`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module tb;
    parameter integer N=8,W=16,T=8,INPUTS=1,OUTPUTS=1,FRAMES=1;
    localparam integer NW=(N>2)?$clog2(N):1,FW=W+$clog2(N);
    localparam integer IW=128+W+2+T,OW=3+2*NW+W+FW+3+64+T;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg [31:0] s_from=0,s_to=0,s_source=0,s_sink=0;
    reg [W-1:0] s_capacity=0;reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_keep,m_first,m_last;
    wire [NW-1:0] m_from,m_to;wire [W-1:0] m_capacity,m_flow;
    wire [FW-1:0] m_total_flow;wire [N-1:0] m_cut;wire [2:0] m_error;
    wire [31:0] m_source,m_sink;wire [T-1:0] m_tag;
    maxflow_mincut #(.NUM_NODES(N),.CAP_W(W),.TAG_W(T)) dut(.*);
    reg [IW-1:0] inputs[0:INPUTS-1];reg [OW-1:0] expected[0:OUTPUTS-1];
    reg [63:0] bounds[0:FRAMES-1];integer tails[0:FRAMES-1];
    wire [IW-1:0] source_payload={s_from,s_to,s_source,s_sink,s_capacity,s_keep,s_last,s_tag};
    wire [OW-1:0] output_base={m_keep,m_first,m_last,m_from,m_to,m_capacity,m_total_flow,m_error,m_source,m_sink,m_tag};
    wire [OW+W+N-1:0] output_payload={output_base,m_flow,m_cut};
    reg source_held=0,result_held=0;
    reg [IW-1:0] old_source;reg [OW+W+N-1:0] old_result;
    integer cycles=0,source_stalls=0,held_cycles=0,resets=0,tail_index=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>12000000) $fatal(1,"bounded watchdog");
        if(rst) begin source_held=0;result_held=0;end
        else begin
            if(source_held && (!s_valid || source_payload!==old_source)) $fatal(1,"source changed while blocked");
            if(result_held && (!m_valid || output_payload!==old_result)) $fatal(1,"held result changed");
            source_held=s_valid && !s_ready;result_held=m_valid && !m_ready;
            if(source_held) source_stalls=source_stalls+1;
            if(result_held) held_cycles=held_cycles+1;
            old_source=source_payload;old_result=output_payload;
        end
    end
    task reset_now;
    begin
        rst=1;s_valid=0;m_ready=0;
        #1;if(s_ready || m_valid) $fatal(1,"reset gating");
        repeat(2) @(negedge clk);rst=0;
        #1;if(s_ready || m_valid || m_total_flow || m_cut) $fatal(1,"reset did not restart clear");
    end endtask
    task await_ready;
        integer elapsed;
    begin
        elapsed=0;
        while(!s_ready) begin @(negedge clk);elapsed=elapsed+1;if(elapsed>N*N+2) $fatal(1,"clear deadline");end
    end endtask
    task put(input [IW-1:0] token);
        integer elapsed;
    begin
        {s_from,s_to,s_source,s_sink,s_capacity,s_keep,s_last,s_tag}=token;s_valid=1;
        elapsed=0;@(posedge clk);
        while(!s_ready) begin @(posedge clk);elapsed=elapsed+1;if(elapsed>6000000) $fatal(1,"input timeout");end
        #1;@(negedge clk);s_valid=0;
    end endtask
    task await_phase(input integer phase);
        integer elapsed;
    begin
        elapsed=0;
        while(!(dut.state==phase && (phase!=0 || dut.clear_index==N*N/2) &&
                (phase!=12 || (source_held && result_held)))) begin
            @(negedge clk);elapsed=elapsed+1;
            if(elapsed>10*N*N+200) $fatal(1,"unreached phase %0d",phase);
        end
    end endtask
    task fresh_empty;
        integer u,v,elapsed;
    begin
        await_ready();put({32'd0,32'd0,32'd0,32'(N-1),{W{1'b0}},1'b0,1'b1,{T{1'b1}}});
        for(u=0;u<N;u=u+1) for(v=0;v<N;v=v+1) begin
            elapsed=0;
            while(!m_valid) begin @(negedge clk);elapsed=elapsed+1;if(elapsed>2*N+8) $fatal(1,"empty rearm timeout");end
            if(!m_keep || m_from!=u || m_to!=v || m_capacity || m_flow || m_total_flow || m_error ||
               m_cut!={{(N-1){1'b0}},1'b1} || m_source!=0 || m_sink!=N-1 || m_tag!={T{1'b1}} ||
               m_first!=(u==0 && v==0) || m_last!=(u==N-1 && v==N-1)) $fatal(1,"reset reuse contaminated");
            m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
        end
    end endtask
    integer phase,ii,oi,fi,hold,elapsed,actual;
    initial begin
        $readmemh("input.hex",inputs);$readmemh("expected.hex",expected);$readmemh("bounds.hex",bounds);
        reset_now();
        for(phase=0;phase<14;phase=phase+1) begin
            reset_now();
            if(phase!=0) begin
                await_ready();
                put({32'd0,32'(N-1),32'((phase==13)?N:0),32'(N-1),{{(W-1){1'b0}},1'b1},
                     1'b1,1'(phase!=1),{T{1'b0}}});
                if(phase==12) begin
                    s_from=0;s_to=0;s_source=0;s_sink=N-1;s_capacity=0;s_keep=0;s_last=1;s_tag=0;s_valid=1;
                end
            end
            await_phase(phase);reset_now();resets=resets+1;fresh_empty();
        end
        await_ready();actual=$fopen("actual.txt","w");if(!actual) $fatal(1,"actual output open");
        fork
            begin
                for(ii=0;ii<INPUTS;ii=ii+1) begin
                    if(ii%7==3) @(negedge clk);
                    {s_from,s_to,s_source,s_sink,s_capacity,s_keep,s_last,s_tag}=inputs[ii];s_valid=1;
                    @(posedge clk);while(!s_ready) @(posedge clk);
                    #1;if(s_last) begin tails[tail_index]=cycles;tail_index=tail_index+1;end
                    @(negedge clk);s_valid=0;
                end
            end
            begin
                fi=0;
                for(oi=0;oi<OUTPUTS;oi=oi+1) begin
                    elapsed=0;
                    while(!m_valid) begin @(negedge clk);elapsed=elapsed+1;if(elapsed>6000000) $fatal(1,"output timeout");end
                    if(m_first) begin
                        if(cycles-tails[fi]>bounds[fi] || (m_error!=0 && cycles!=tails[fi]))
                            $fatal(1,"first-valid latency %0d bound %0d frame %0d",cycles-tails[fi],bounds[fi],fi);
                    end
                    repeat(3) begin
                        if(!m_valid || output_base!==expected[oi] || m_flow>m_capacity)
                            $fatal(1,"output %0d mismatch got=%h expected=%h",oi,output_base,expected[oi]);
                        @(negedge clk);
                    end
                    $fwrite(actual,"%h %h\n",m_flow,m_cut);
                    if(m_last) fi=fi+1;
                    m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
                end
            end
        join
        $fclose(actual);
        if(tail_index!=FRAMES || fi!=FRAMES || resets!=14 || source_stalls==0 || held_cycles<3*OUTPUTS)
            $fatal(1,"coverage mismatch");
        repeat(N*N+3) begin @(negedge clk);if(m_valid) $fatal(1,"spurious output");end
        $display("PASS maxflow N=%0d W=%0d T=%0d frames=%0d outputs=%0d source_stalls=%0d held=%0d reset_probes=%0d",
                 N,W,T,FRAMES,OUTPUTS,source_stalls,held_cycles,resets);
        $finish;
    end
endmodule
