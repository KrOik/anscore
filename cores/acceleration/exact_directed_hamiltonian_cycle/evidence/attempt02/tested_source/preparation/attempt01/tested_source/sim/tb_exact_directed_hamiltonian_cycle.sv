// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_exact_directed_hamiltonian_cycle;
    parameter integer NUM_NODES=8,WEIGHT_W=16,TAG_W=8;
    localparam integer IW=$clog2(NUM_NODES),CW=$clog2(NUM_NODES+1);
    localparam integer SW=WEIGHT_W+IW,OW=5+TAG_W+CW+IW+SW;
    reg clk=0,rst=1,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    wire s_ready,m_valid,m_keep,m_last,m_feasible;
    reg [31:0] s_from=0,s_to=0;
    reg signed [WEIGHT_W-1:0] s_weight=0;
    reg s_present=0,s_keep=0,s_last=0;
    reg [TAG_W-1:0] s_tag=0;
    wire [1:0] m_error;
    wire [TAG_W-1:0] m_tag;
    wire [CW-1:0] m_position;
    wire [IW-1:0] m_vertex;
    wire signed [SW-1:0] m_cost;
    wire [OW-1:0] payload={m_keep,m_last,m_feasible,m_error,m_tag,m_position,m_vertex,m_cost};
    exact_directed_hamiltonian_cycle #(.NUM_NODES(NUM_NODES),.WEIGHT_W(WEIGHT_W),.TAG_W(TAG_W)) dut(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_from(s_from),.s_to(s_to),.s_weight(s_weight),.s_present(s_present),
        .s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_keep(m_keep),.m_last(m_last),
        .m_feasible(m_feasible),.m_error(m_error),.m_tag(m_tag),
        .m_position(m_position),.m_vertex(m_vertex),.m_cost(m_cost)
    );
    integer cases,ids[0:31],kinds[0:31],aborts[0:31],nt[0:31],nr[0:31];
    integer tokens[0:31][0:127][0:6],rows[0:31][0:15][0:7];
    integer fd,rc,tmp,fi,j,f,mode,reset_suite,pending_future=0;
    string fixture_path;

    task automatic set_input(input integer a,input integer b);
        begin
            s_from=32'(tokens[a][b][0]);s_to=32'(tokens[a][b][1]);
            s_weight=WEIGHT_W'(tokens[a][b][2]);s_present=1'(tokens[a][b][3]);
            s_keep=1'(tokens[a][b][4]);s_last=1'(tokens[a][b][5]);
            s_tag=TAG_W'(tokens[a][b][6]);s_valid=1;
        end
    endtask
    task automatic check_row(input integer a,input integer b);
        begin
            if(m_keep!==1'(rows[a][b][0]) || m_feasible!==1'(rows[a][b][1]) ||
               m_error!==2'(rows[a][b][2]) || m_tag!==TAG_W'(rows[a][b][3]) ||
               m_position!==CW'(rows[a][b][4]) || m_vertex!==IW'(rows[a][b][5]) ||
               m_cost!==SW'(rows[a][b][6]) || m_last!==1'(rows[a][b][7]))
                $fatal(1,"exact output tuple mismatch case=%0d row=%0d",ids[a],b);
        end
    endtask
    task automatic drive_frame(input integer a,input integer schedule,input integer code);
        integer ii,oo,cycle,finished,aborted,pending,is_future,next_case;
        integer last_holds,other_holds,held_cycles,budget,probe;
        reg previous_held;
        reg [OW-1:0] held_payload;
        begin
            ii=0;oo=0;cycle=0;finished=0;aborted=0;last_holds=0;other_holds=0;
            held_cycles=0;previous_held=0;held_payload=0;
            pending=pending_future;pending_future=0;is_future=0;
            next_case=(code==6)?a+1:((a+1<cases && code==0)?a+1:-1);
            if(pending)begin
                if(s_valid!==1 || s_from!==32'(tokens[a][0][0]) ||
                   s_to!==32'(tokens[a][0][1]) || s_weight!==WEIGHT_W'(tokens[a][0][2]) ||
                   s_present!==1'(tokens[a][0][3]) || s_keep!==1'(tokens[a][0][4]) ||
                   s_last!==1'(tokens[a][0][5]) || s_tag!==TAG_W'(tokens[a][0][6]))
                    $fatal(1,"future first beat changed across owner boundary");
            end
            budget=NUM_NODES*NUM_NODES+nt[a]+4*(NUM_NODES-1)*(NUM_NODES-1)*
                   ((1<<(NUM_NODES-1))-1)+8*(NUM_NODES-1)+NUM_NODES+16+
                   10*nt[a]+10*(NUM_NODES+1)+100;
            while(!finished)begin
                @(negedge clk);
                m_ready=(schedule==0 || (cycle%7!=1 && cycle%7!=2));
                if(!pending)begin
                    if(ii<nt[a] && (schedule==0 || (cycle%11!=2 && cycle%11!=3)))begin
                        set_input(a,ii);pending=1;is_future=0;
                    end else if(ii==nt[a] && next_case>=0 && (schedule==1 || code==6))begin
                        set_input(next_case,0);pending=1;is_future=1;
                        $display("OFFER %0d %0d %0d",ids[a],ids[next_case],cycle);
                    end else s_valid=0;
                end
                if(m_valid && m_last && (schedule==1 || code==6) && last_holds<3)begin
                    m_ready=0;last_holds=last_holds+1;
                end
                if(m_valid && !m_last && code==5 && other_holds<3)begin
                    m_ready=0;other_holds=other_holds+1;
                end
                probe=0;
                if(code==1 && ii==1 && ii<nt[a])probe=1;
                else if(code==2 && dut.state==7)probe=1;
                else if(code==3 && dut.state==9 && dut.remainder!=0 && dut.best_valid)probe=1;
                else if(code==4 && dut.state==14)probe=1;
                else if(code==5 && m_valid && !m_last && !m_ready)probe=1;
                else if(code==6 && m_valid && m_last && !m_ready && pending && is_future)probe=1;
                if(probe)begin
                    $display("PROBE %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",ids[a],code,ii,oo,dut.state,m_valid,m_ready,s_valid,s_ready,dut.mask,dut.remainder,dut.node,dut.scan,dut.best_valid,dut.candidate_valid,$signed(dut.sum_q));
                    rst=1;aborted=1;
                end
                @(posedge clk);
                if(rst)begin
                    if(s_ready!==0 || m_valid!==0)$fatal(1,"reset handshake mask");
                    $display("RESETEDGE %0d 0",ids[a]);finished=1;
                end else begin
                    if(previous_held && (m_valid!==1 || payload!==held_payload))
                        $fatal(1,"held output changed");
                    previous_held=m_valid && !m_ready;held_payload=payload;
                    if(previous_held)held_cycles=held_cycles+1;
                    if(s_valid && s_ready)begin
                        if(ii>=nt[a] || is_future)$fatal(1,"future owner accepted before current terminal");
                        $display("IN %0d %0d %0d %0d %0d %0d %0d %0d %0d",ids[a],ii,s_from,s_to,$signed(s_weight),s_present,s_keep,s_last,s_tag);
                        ii=ii+1;pending=0;
                    end
                    if(m_valid && m_ready)begin
                        if(ii!=nt[a] || oo>=nr[a])$fatal(1,"early or extra output");
                        check_row(a,oo);
                        if(code!=0)$display("ABORTREC %0d %0d %0d %0d %0d %0d %0d %0d %0d",ids[a],m_keep,m_feasible,m_error,m_tag,m_position,m_vertex,$signed(m_cost),m_last);
                        else $display("REC %0d %0d %0d %0d %0d %0d %0d %0d %0d",ids[a],m_keep,m_feasible,m_error,m_tag,m_position,m_vertex,$signed(m_cost),m_last);
                        oo=oo+1;
                        if(m_last)finished=1;
                    end
                end
                cycle=cycle+1;
                if(cycle>budget)$fatal(1,"per-owner deterministic cycle budget exceeded");
            end
            if(code!=0 && !aborted)$fatal(1,"unreached reset predicate");
            if(code==0)begin
                if(aborted || ii!=nt[a] || oo!=nr[a])$fatal(1,"incomplete frame");
                if(schedule==1 && held_cycles<3)$fatal(1,"held final output not exercised");
                $display("FRAME %0d %0d %0d %0d %0d",ids[a],ii,oo,cycle,held_cycles);
            end
            @(negedge clk);
            if(aborted)begin s_valid=0;m_ready=0;pending_future=0;end
            else if(pending && is_future)pending_future=1;
            else begin s_valid=0;pending_future=0;end
        end
    endtask
    task automatic finish_reset(input integer case_id);
        integer edge_index;
        begin
            for(edge_index=1;edge_index<=2;edge_index=edge_index+1)begin
                @(posedge clk);
                if(s_ready!==0 || m_valid!==0)$fatal(1,"held reset handshake mask");
                $display("RESETEDGE %0d %0d",case_id,edge_index);
                @(negedge clk);
            end
            rst=0;s_valid=0;m_ready=0;pending_future=0;
        end
    endtask
    initial begin
        if(!$value$plusargs("fixture=%s",fixture_path))$fatal(1,"missing fixture");
        if(!$value$plusargs("mode=%d",mode) || mode<0 || mode>1)$fatal(1,"bad mode");
        if(!$value$plusargs("reset=%d",reset_suite) || reset_suite<0 || reset_suite>1)$fatal(1,"bad reset mode");
        fd=$fopen(fixture_path,"r");if(!fd)$fatal(1,"fixture open");
        rc=$fscanf(fd,"%d",cases);if(rc!=1 || cases<1 || cases>32)$fatal(1,"fixture count");
        for(fi=0;fi<cases;fi=fi+1)begin
            // Scalar scan destinations avoid Icarus multidimensional lvalue lowering.
            rc=$fscanf(fd,"%d",tmp);if(rc!=1)$fatal(1,"id");ids[fi]=tmp;
            rc=$fscanf(fd,"%d",tmp);if(rc!=1)$fatal(1,"kind");kinds[fi]=tmp;
            rc=$fscanf(fd,"%d",tmp);if(rc!=1)$fatal(1,"abort");aborts[fi]=tmp;
            rc=$fscanf(fd,"%d",tmp);if(rc!=1 || tmp<1 || tmp>128)$fatal(1,"tokens");nt[fi]=tmp;
            rc=$fscanf(fd,"%d",tmp);if(rc!=1 || tmp<1 || tmp>16)$fatal(1,"rows");nr[fi]=tmp;
            for(j=0;j<nt[fi];j=j+1)for(f=0;f<7;f=f+1)begin
                rc=$fscanf(fd,"%d",tmp);if(rc!=1)$fatal(1,"token field");tokens[fi][j][f]=tmp;
            end
            for(j=0;j<nr[fi];j=j+1)for(f=0;f<8;f=f+1)begin
                rc=$fscanf(fd,"%d",tmp);if(rc!=1)$fatal(1,"row field");rows[fi][j][f]=tmp;
            end
        end
        rc=$fscanf(fd,"%d",tmp);if(rc!=-1)$fatal(1,"trailing fixture content");$fclose(fd);
        repeat(3)@(posedge clk);@(negedge clk);rst=0;
        if(reset_suite)begin
            if(cases%2!=0)$fatal(1,"reset pair count");
            for(fi=0;fi<cases;fi=fi+2)begin
                if(kinds[fi]!=1 || kinds[fi+1]!=2 || aborts[fi]<1 || aborts[fi]>6 || aborts[fi+1]!=0)
                    $fatal(1,"reset pair metadata");
                drive_frame(fi,1,aborts[fi]);finish_reset(ids[fi]);
                drive_frame(fi+1,1,0);$display("RESETDONE %0d %0d",ids[fi],ids[fi+1]);
            end
        end else for(fi=0;fi<cases;fi=fi+1)begin
            if(kinds[fi]!=0 || aborts[fi]!=0)$fatal(1,"normal metadata");
            drive_frame(fi,mode,0);
        end
        @(negedge clk);s_valid=0;m_ready=1;
        repeat(3)begin @(posedge clk);if(m_valid)$fatal(1,"extra terminal output");end
        $display("PASS %0d %0d %0d",mode,reset_suite,cases);
        $finish;
    end
endmodule
