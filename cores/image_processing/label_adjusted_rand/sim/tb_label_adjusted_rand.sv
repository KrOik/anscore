// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_label_adjusted_rand;
    parameter integer W=64,H=64,L=4,K=16,T=8;
    localparam integer N=W*H,C=$clog2(N+1);
    localparam [63:0] PMAX=(64'd1*N*(N-1))/2;
    localparam integer P=(PMAX<1)?1:$clog2(PMAX+1),U=2*P+2,D=2*P+1,MW=P+1;
    localparam integer RW=U+D+C+4*P+4+T,TABLE=K*K;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_sof=0,s_eol=0,m_ready=0;
    reg [L-1:0] s_a=0,s_b=0;reg [T-1:0] s_tag=0;
    wire s_ready,m_valid;
    wire signed [U-1:0] m_ari_numerator;
    wire [D-1:0] m_ari_denominator;
    wire [C-1:0] m_count;
    wire [P-1:0] m_pairs,m_same_a,m_same_b,m_same_both;
    wire m_equivalent,m_degenerate;
    wire [1:0] m_errors;wire [T-1:0] m_tag;
    label_adjusted_rand #(.WIDTH(W),.HEIGHT(H),.LABEL_W(L),.LABELS(K),.TAG_W(T)) dut(.*);
    wire [RW-1:0] result={m_ari_numerator,m_ari_denominator,m_count,m_pairs,
        m_same_a,m_same_b,m_same_both,m_equivalent,m_degenerate,m_errors,m_tag};
    wire [2*L+T+2:0] request={s_a,s_b,s_keep,s_sof,s_eol,s_tag};
    reg [RW-1:0] held_result;
    reg [2*L+T+2:0] held_request;
    bit held=0,source_held=0,main_checks=0;
    integer cycles=0,tail_cycle=0,source_stalls=0,held_cycles=0,phase_resets=0,frames=0;
    integer phase,i;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>5000000) $fatal(1,"bounded watchdog");
        if(rst) begin held<=0;source_held<=0;end
        else begin
            if(held && (!m_valid || result!==held_result)) $fatal(1,"held result changed");
            if(source_held && (!s_valid || request!==held_request)) $fatal(1,"source violated hold");
            held<=m_valid&&!m_ready;held_result<=result;
            source_held<=s_valid&&!s_ready;held_request<=request;
            if(m_valid && s_ready) $fatal(1,"ownership overlap");
            if(dut.state==dut.COMMIT && (dut.pbc_sum<(dut.bc<<1) ||
               dut.numerator_wide!=$signed(dut.numerator_wide[U-1:0]) ||
               dut.denominator_wide[D])) $fatal(1,"ARI intermediate range");
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready || m_valid) $fatal(1,"reset transfer gating");
            repeat(2) @(negedge clk);rst=0;
            #1;if(m_valid || dut.state!=dut.CLEAR || m_count!==0) $fatal(1,"reset state");
        end
    endtask
    task automatic put(input [L-1:0] a,b,input bit keep,sof,eol,
                       input [T-1:0] tag,input integer gap,input bit tail);
        integer ticks;
        begin
            repeat(gap) @(negedge clk);
            s_valid=1;s_a=a;s_b=b;s_keep=keep;s_sof=sof;s_eol=eol;s_tag=tag;
            ticks=0;@(posedge clk);
            while(!s_ready) begin
                ticks=ticks+1;source_stalls=source_stalls+1;
                if(ticks>TABLE+4) $fatal(1,"source stall bound");
                @(posedge clk);
            end
            #1;if(tail) tail_cycle=cycles;
            @(negedge clk);s_valid=0;s_a=~a;s_b=~b;s_keep=~keep;s_sof=~sof;s_eol=~eol;s_tag=~tag;
        end
    endtask
    task automatic get_result(input [U-1:0] numerator,input [D-1:0] denominator,
        input [C-1:0] count,input [P-1:0] pairs,same_a,same_b,both,
        input bit equivalent,degenerate,input [1:0] errors,input [T-1:0] tag,
        input integer delay,hold);
        integer ticks;
        begin
            ticks=0;
            while(!m_valid) begin
                if(s_ready) $fatal(1,"admitted during solve");
                @(negedge clk);ticks=ticks+1;
                if(ticks>3*MW+10) $fatal(1,"result timeout");
            end
            if(cycles-tail_cycle!=delay) $fatal(1,"tail schedule got=%0d expected=%0d",cycles-tail_cycle,delay);
            repeat(hold+1) begin
                if(!m_valid || result!=={numerator,denominator,count,pairs,same_a,same_b,both,equivalent,degenerate,errors,tag})
                    $fatal(1,"metric mismatch frame=%0d got=%h expected=%h",frames,result,{numerator,denominator,count,pairs,same_a,same_b,both,equivalent,degenerate,errors,tag});
                if(errors==0 && (m_ari_denominator==0 || m_same_both>m_same_a || m_same_both>m_same_b || m_same_a>m_pairs || m_same_b>m_pairs))
                    $fatal(1,"pair domain");
                held_cycles=held_cycles+1;@(negedge clk);
            end
            m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
            if(m_valid) $fatal(1,"duplicate result");
            if(main_checks) frames=frames+1;
        end
    endtask
    task automatic wait_state(input integer target);
        integer ticks;
        begin
            ticks=0;
            while(dut.state!=target) begin
                @(negedge clk);ticks=ticks+1;
                if(ticks>((target==1)?TABLE+2:3*MW+10)) $fatal(1,"missing reset phase %0d",target);
            end
        end
    endtask
    task automatic singleton_recovery;
        integer n;
        begin
            for(n=0;n<N;n=n+1) put(0,0,n==0,n==0,n%W==W-1,{T{1'b1}},0,n==N-1);
            get_result(1,1,1,0,0,0,0,1,1,0,{T{1'b1}},3*MW+5+(N==1),3);
        end
    endtask
    initial begin
        reset_now();
        for(phase=0;phase<12;phase=phase+1) begin
            if(phase!=10 || N>1) begin
                if(phase==0) begin
                    s_valid=1;s_a=0;s_b=0;s_keep=1;s_sof=1;s_eol=W==1;
                    while(dut.clear_address!=TABLE/2) @(negedge clk);
                end else if(phase==1) begin
                    wait_state(1);
                    if(N>1) begin put(0,0,1,1,W==1,0,0,0);wait_state(1);end
                end else if(phase==2) begin put(0,0,1,1,W==1,0,0,0);wait_state(2);end
                else if(phase==10) begin
                    if(K<(1<<L)) put(K,0,1,1,W==1,0,0,0);
                    else put(0,0,1,0,W==1,0,0,0);
                    if(m_errors==0) $fatal(1,"error-drain probe missing");
                end else begin
                    for(i=0;i<N;i=i+1) put(0,0,0,(i==0)&&(phase!=11),i%W==W-1,0,0,i==N-1);
                    if(phase==8 || phase==9 || phase==5) begin
                        while(!(dut.state==dut.MUL_RUN && dut.operation==((phase==8)?0:(phase==9)?1:2) && dut.bit_count==MW/2)) @(negedge clk);
                    end else wait_state((phase==11)?7:phase);
                    if(phase==7 || phase==11) begin
                        s_valid=1;s_a=0;s_b=0;s_keep=1;s_sof=1;s_eol=W==1;s_tag=0;
                        while(!(held && source_held)) @(negedge clk);
                    end
                end
                reset_now();phase_resets=phase_resets+1;singleton_recovery();reset_now();
            end
        end
        main_checks=1;
        `include "vectors.svh"
        main_checks=0;
        repeat(4) begin @(negedge clk);if(m_valid) $fatal(1,"spurious result");end
        if(source_stalls==0 || held_cycles==0) $fatal(1,"missing service evidence");
        $display("PASS ARI W=%0d H=%0d L=%0d K=%0d T=%0d frames=%0d source_stalls=%0d held=%0d resets=%0d",
                 W,H,L,K,T,frames,source_stalls,held_cycles,phase_resets);
        $finish;
    end
endmodule
