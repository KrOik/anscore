// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_price_level_ioc_matcher;
    parameter integer L=3,P=8,Q=8,T=8;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,c_valid=0,r_ready=0,i_valid=0,f_ready=0,d_ready=0;
    wire c_ready,r_valid,i_ready,f_valid,d_valid;
    reg [3:0] c_op=0;reg c_side=0;
    reg [P-1:0] c_price=0;reg [Q-1:0] c_quantity=0;
    reg [31:0] c_rank=0;reg [T-1:0] c_tag=0;
    wire [3:0] r_op;wire r_side,r_found;wire [2:0] r_status;
    wire [P-1:0] r_price;wire [Q-1:0] r_quantity,r_previous;
    wire [31:0] r_bid_levels,r_ask_levels;wire [T-1:0] r_tag;
    reg i_buy=0,i_market=0;reg [P-1:0] i_limit=0;reg [Q-1:0] i_quantity=0;reg [T-1:0] i_tag=0;
    wire f_buy;wire [P-1:0] f_price;wire [Q-1:0] f_quantity,f_remaining;
    wire [31:0] f_index;wire [T-1:0] f_tag;
    wire [2:0] d_reason;wire [Q-1:0] d_filled,d_remaining;
    wire [31:0] d_fills,d_bid_levels,d_ask_levels;wire [T-1:0] d_tag;
    price_level_ioc_matcher #(.LEVELS(L),.PRICE_W(P),.QTY_W(Q),.TAG_W(T)) dut(.*);
    integer fd,rc,kind,op,side,found,status,bids,asks,n,why,phase,j,k,steps=0,fills=0;
    reg [63:0] price,quantity,rank,tag,afterq,previous,filled,remaining;
    reg [63:0] ep,eq,er,et,ei;
    reg buy,market;reg [63:0] lim;
    reg [1023:0] file;
    task edge_tick;begin @(posedge clk);#1;end endtask
    task neg_tick;begin @(negedge clk);end endtask
    task busy_check;begin
        if(c_ready||i_ready)$fatal(1,"ownership lost step %0d",steps);
    end endtask
    task reset_all;begin
        neg_tick();rst_n=0;c_valid=0;i_valid=0;r_ready=0;f_ready=0;d_ready=0;
        #1;if(c_ready||i_ready||r_valid||f_valid||d_valid)$fatal(1,"reset handshake");
        repeat(3)edge_tick();neg_tick();rst_n=1;repeat(3)edge_tick();
        if(r_valid||f_valid||d_valid)$fatal(1,"ghost after reset");
    end endtask
    task launch_maint;begin
        neg_tick();c_op=op;c_side=side;c_price=price;c_quantity=quantity;c_rank=rank;c_tag=tag;c_valid=1;
        do begin @(posedge clk);end while(!c_ready);
        #1;neg_tick();c_valid=0;
    end endtask
    task launch_ioc;begin
        neg_tick();i_buy=buy;i_market=market;i_limit=lim;i_quantity=quantity;i_tag=tag;i_valid=1;
        do begin @(posedge clk);end while(!i_ready);
        #1;neg_tick();i_valid=0;
    end endtask
    task check_maint;begin
        if({r_op,r_side,r_status,r_found,r_price,r_quantity,r_previous,r_bid_levels,r_ask_levels,r_tag}!==
           {4'(op),1'(side),3'(status),1'(found),P'(price),Q'(afterq),Q'(previous),32'(bids),32'(asks),T'(tag)})
            $fatal(1,"maintenance step %0d status %0d/%0d price %0d/%0d qty %0d/%0d prev %0d/%0d counts %0d,%0d/%0d,%0d",steps,r_status,status,r_price,price,r_quantity,afterq,r_previous,previous,r_bid_levels,r_ask_levels,bids,asks);
    end endtask
    task check_fill;begin
        if({f_buy,f_price,f_quantity,f_remaining,f_index,f_tag}!=={buy,P'(ep),Q'(eq),Q'(er),32'(ei),T'(et)})
            $fatal(1,"fill step %0d price %0d/%0d qty %0d/%0d remain %0d/%0d index %0d/%0d",steps,f_price,ep,f_quantity,eq,f_remaining,er,f_index,ei);
    end endtask
    task check_done;begin
        if({d_reason,d_filled,d_remaining,d_fills,d_bid_levels,d_ask_levels,d_tag}!==
           {3'(why),Q'(filled),Q'(remaining),32'(n),32'(bids),32'(asks),T'(tag)})
            $fatal(1,"done step %0d why %0d/%0d filled %0d/%0d remain %0d/%0d fills %0d/%0d counts %0d,%0d/%0d,%0d",steps,d_reason,why,d_filled,filled,d_remaining,remaining,d_fills,n,d_bid_levels,d_ask_levels,bids,asks);
    end endtask
    initial begin
        if(!$value$plusargs("vectors=%s",file))$fatal(1,"missing vectors");
        fd=$fopen(file,"r");if(!fd)$fatal(1,"vectors open");reset_all();
        while(!$feof(fd))begin
            rc=$fscanf(fd,"%d",kind);
            if(rc==1)begin
                steps=steps+1;
                case(kind)
                    0:begin
                        rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d",op,side,ep,quantity,rank,tag,status,found,price,afterq,previous,bids,asks);
                        if(rc!=13)$fatal(1,"maintenance vector");
                        er=price;price=ep;launch_maint();price=er;
                        while(!r_valid)begin edge_tick();if(f_valid||d_valid)$fatal(1,"wrong maintenance output");end
                        for(k=0;k<1+steps%4;k=k+1)begin
                            check_maint();busy_check();neg_tick();c_valid=1;i_valid=1;c_op=15;i_quantity=0;
                            edge_tick();if(!r_valid)$fatal(1,"lost maintenance reply");
                        end
                        check_maint();neg_tick();c_valid=0;i_valid=0;r_ready=1;edge_tick();neg_tick();r_ready=0;
                    end
                    1:begin
                        rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d",buy,market,lim,quantity,tag,n,why,filled,remaining,bids,asks);
                        if(rc!=11)$fatal(1,"IOC vector");launch_ioc();
                        for(j=0;j<n;j=j+1)begin
                            rc=$fscanf(fd,"%d %d %d %d %d",ep,eq,er,ei,et);if(rc!=5)$fatal(1,"fill vector");
                            while(!f_valid)begin edge_tick();busy_check();if(r_valid||d_valid)$fatal(1,"early done step %0d",steps);end
                            for(k=0;k<1+(steps+j)%5;k=k+1)begin
                                check_fill();busy_check();neg_tick();c_valid=1;i_valid=1;c_op=7;i_quantity=1;
                                edge_tick();if(!f_valid||d_valid)$fatal(1,"fill lost while stalled");
                            end
                            check_fill();neg_tick();c_valid=0;i_valid=0;f_ready=1;edge_tick();neg_tick();f_ready=0;fills=fills+1;
                        end
                        while(!d_valid)begin edge_tick();busy_check();if(f_valid||r_valid)$fatal(1,"extra output step %0d",steps);end
                        for(k=0;k<2+steps%4;k=k+1)begin
                            check_done();busy_check();neg_tick();c_valid=1;i_valid=1;c_op=7;i_quantity=1;
                            edge_tick();if(!d_valid)$fatal(1,"lost done");
                        end
                        check_done();neg_tick();c_valid=0;i_valid=0;d_ready=1;edge_tick();neg_tick();d_ready=0;
                    end
                    2:begin
                        rc=$fscanf(fd,"%d",phase);if(rc!=1)$fatal(1,"reset vector");
                        buy=1;market=1;lim=0;quantity=(phase==2)?0:1;tag=0;
                        if(phase==3)begin op=0;side=1;price=0;quantity=1;rank=0;launch_maint();while(!r_valid)edge_tick();end
                        else begin
                            launch_ioc();
                            if(phase==0)repeat(4)edge_tick();
                            else if(phase==1)while(!f_valid)edge_tick();
                            else while(!d_valid)edge_tick();
                        end
                        repeat(3)begin busy_check();edge_tick();end
                        reset_all();
                    end
                    3:begin
                        // Simultaneous valid: maintenance wins, including held reply.
                        neg_tick();c_op=0;c_side=1;c_price=0;c_quantity=1;c_rank=0;c_tag=0;c_valid=1;
                        i_buy=1;i_market=1;i_limit=0;i_quantity=0;i_tag=0;i_valid=1;
                        do begin @(posedge clk);if(i_ready)$fatal(1,"priority");end while(!c_ready);
                        #1;neg_tick();c_valid=0;
                        while(!r_valid)begin edge_tick();if(i_ready)$fatal(1,"IOC accepted before maintenance");end
                        repeat(4)begin busy_check();edge_tick();end
                        neg_tick();r_ready=1;edge_tick();neg_tick();r_ready=0;
                        do begin @(posedge clk);end while(!i_ready);
                        #1;neg_tick();i_valid=0;while(!d_valid)edge_tick();
                        if(d_reason!=3||d_ask_levels!=1||d_bid_levels!=0)$fatal(1,"priority completion");
                        neg_tick();d_ready=1;edge_tick();neg_tick();d_ready=0;
                    end
                    default:$fatal(1,"bad vector");
                endcase
            end
        end
        repeat(4)edge_tick();if(r_valid||f_valid||d_valid)$fatal(1,"trailing output");
        $display("PASS price_level_ioc_matcher L=%0d P=%0d Q=%0d T=%0d steps=%0d fills=%0d",L,P,Q,T,steps,fills);$finish;
    end
    initial begin repeat(3000000)@(posedge clk);$fatal(1,"cycle watchdog");end
endmodule
