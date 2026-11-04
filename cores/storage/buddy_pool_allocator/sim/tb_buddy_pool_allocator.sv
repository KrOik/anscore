// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_buddy_pool_allocator;
    parameter integer M=6,T=8;
    localparam integer U=1<<M, OW=($clog2(M+2)>1)?$clog2(M+2):1;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,sv=0,mr=0;
    reg [1:0] op=0;reg [3:0] ord=0;reg [31:0] base=0;
    reg [T-1:0] tag=0;
    wire sr,mv;wire [1:0] rop,status;wire [3:0] rord,largest;
    wire [31:0] rbase;wire [T-1:0] rtag;wire [M:0] units;wire has_free;
    buddy_pool_allocator #(.MAX_ORDER(M),.TAG_W(T)) dut (
        .clk(clk),.rst(rst),.s_valid(sv),.s_ready(sr),.s_op(op),.s_order(ord),
        .s_base(base),.s_tag(tag),.m_valid(mv),.m_ready(mr),.m_op(rop),
        .m_status(status),.m_order(rord),.m_base(rbase),.m_tag(rtag),
        .m_free_units(units),.m_has_free(has_free),.m_largest_order(largest));
    integer cycle=0,records=0,responses=0,markers=0,held=0,probes=0,source_stalls=0;
    integer nodes_checked=0,unit_checks=0,watchdog=0;
    always @(posedge clk) begin cycle<=cycle+1;watchdog<=watchdog+1;
        if(watchdog>3000000)$fatal(1,"watchdog");end
    reg [U-1:0] occupied,heads;
    task automatic inspect(input integer idx,input integer level,input integer addr,output integer avail);
        integer k,a,b,kind,stored;
        begin
            nodes_checked=nodes_checked+1;
            kind=dut.tree[idx]>>OW;stored=dut.tree[idx]&((1<<OW)-1);
            if(kind==0 || kind==1) begin
                for(k=0;k<(1<<level);k=k+1) begin
                    unit_checks=unit_checks+1;
                    if(occupied[addr+k] !== (kind==1))$fatal(1,"physical occupancy mismatch addr=%0d",addr+k);
                    if(heads[addr+k] !== (kind==1 && k==0))$fatal(1,"physical allocation boundary mismatch");
                end
                avail=(kind==0)?level+1:0;
            end else if(kind==2 && level>0) begin
                inspect(idx*2+1,level-1,addr,a);
                inspect(idx*2+2,level-1,addr+(1<<(level-1)),b);
                if(a==level && b==level)$fatal(1,"unmerged free buddies");
                avail=(a>b)?a:b;
            end else $fatal(1,"invalid reachable metadata node");
            if(stored!==avail)$fatal(1,"summary mismatch idx=%0d stored=%0d expected=%0d",idx,stored,avail);
        end
    endtask
    task automatic reset_now;
        begin
            rst=1;sv=0;mr=0;
            #1;if(sr||mv)$fatal(1,"reset interface gating");
            @(posedge clk);@(negedge clk);rst=0;mr=1;
            if(dut.state!==0 || dut.free_units!==U || dut.tree[0]!==M+1)$fatal(1,"root reset state");
        end
    endtask
    task automatic launch(input integer xop,input integer xo,input reg [31:0] xb,input reg [T-1:0] xt);
        begin
            @(negedge clk);sv=1;op=xop;ord=xo;base=xb;tag=xt;
            while(!sr)@(negedge clk);
            @(posedge clk);@(negedge clk);sv=0;
            // Invalid fields are deliberately disturbed immediately after capture.
            op=~op;ord=~ord;base=~base;tag=~tag;
        end
    endtask
    task automatic prepare_alloc;
        begin
            mr=1;launch(0,0,0,1);
            while(!mv)@(negedge clk);
            if(status || rbase)$fatal(1,"probe preallocation");
            @(posedge clk);@(negedge clk);
        end
    endtask
    task automatic cancel_at(input integer wanted);
        integer elapsed;
        begin
            reset_now();
            if(wanted==3 || wanted==4 || wanted==9)prepare_alloc();
            mr=0;
            if(wanted!=0)begin
                if(wanted==9)launch(1,0,0,2);
                else if(wanted==14)launch(2,15,32'hffffffff,2);
                else launch(0,0,0,2);
            end
            elapsed=0;
            while(dut.state!=wanted)begin
                @(negedge clk);elapsed=elapsed+1;
                if(elapsed>12*(M+1)+8)$fatal(1,"unreached reset target=%0d",wanted);
            end
            // No additional edge separates the observation from reset assertion.
            reset_now();probes=probes+1;
        end
    endtask
    integer fd,rc,kind,vop,vo,vs,vhas,vlargest,vfree,dummy,started,waited,n,k,a;
    reg [31:0] vb,vt,veb;
    reg [4095:0] vector_path;
    reg [2+2+4+32+T+(M+1)+1+4-1:0] saved;
    initial begin
        if(!$value$plusargs("vectors=%s",vector_path))$fatal(1,"missing vectors");
        reset_now();
        for(n=0;n<16;n=n+1)
            if(M>0 || n==0 || n==1 || n==2 || n==8 || n==9 || n==14 || n==15)cancel_at(n);
        // A real stable next-command offer remains blocked throughout held output.
        mr=0;launch(0,0,0,3);
        while(!mv)@(negedge clk);
        saved={rop,status,rord,rbase,rtag,units,has_free,largest};
        sv=1;op=1;ord=0;base=0;tag=7;
        repeat(4)begin
            if(sr || !mv || {rop,status,rord,rbase,rtag,units,has_free,largest}!==saved)$fatal(1,"busy offer/held response");
            source_stalls=source_stalls+1;@(negedge clk);
        end
        reset_now();
        fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"vector open");
        while(!$feof(fd))begin
            rc=$fscanf(fd,"%d %d %d %h %h %d %h %d %d %d %h %h\n",kind,vop,vo,vb,vt,vs,veb,vfree,vhas,vlargest,occupied,heads);
            if(rc!=12)$fatal(1,"bad vector record rc=%0d",rc);
            records=records+1;
            if(kind==1)begin
                reset_now();markers=markers+1;inspect(0,M,0,a);
            end else begin
                mr=0;launch(vop,vo,vb,vt[T-1:0]);started=cycle;waited=0;
                while(!mv)begin
                    if(sr)$fatal(1,"ready while command busy");
                    @(negedge clk);waited=waited+1;
                    if(waited>12*(M+1)+8)$fatal(1,"latency bound");
                end
                if({rop,status,rord,rbase,rtag,units,has_free,largest} !==
                    {vop[1:0],vs[1:0],vo[3:0],veb,vt[T-1:0],vfree[M:0],vhas[0],vlargest[3:0]})
                    $fatal(1,"response record=%0d op=%0d order=%0d base=%h got status=%0d base=%h free=%0d largest=%0d expected status=%0d base=%h free=%0d largest=%0d",records,vop,vo,vb,status,rbase,units,largest,vs,veb,vfree,vlargest);
                inspect(0,M,0,a);
                if(dut.free_units!==vfree[M:0])$fatal(1,"free unit counter");
                saved={rop,status,rord,rbase,rtag,units,has_free,largest};
                for(k=0;k<2+(records%3);k=k+1)begin
                    @(negedge clk);held=held+1;
                    if(sr || !mv || {rop,status,rord,rbase,rtag,units,has_free,largest}!==saved)$fatal(1,"held response changed");
                end
                mr=1;@(posedge clk);@(negedge clk);mr=0;
                if(mv || !sr)$fatal(1,"response retirement");
                responses=responses+1;
            end
        end
        $fclose(fd);
        $display("PASS buddy M=%0d T=%0d records=%0d responses=%0d reset_markers=%0d phase_resets=%0d source_stalls=%0d held=%0d nodes=%0d unit_checks=%0d",M,T,records,responses,markers,probes,source_stalls,held,nodes_checked,unit_checks);
        $finish;
    end
endmodule
