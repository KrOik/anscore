// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_price_time_order_matcher;
    parameter integer N=5,P=9,Q=7,T=4;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,c_valid=0,f_ready=0,r_ready=0;
    reg [2:0] c_op=0;reg [63:0] c_order=0;reg c_sell=0;
    reg [P-1:0] c_price=0;reg [Q-1:0] c_quantity=0;reg [T-1:0] c_tag=0;
    wire c_ready,f_valid,r_valid,busy,faulted;
    wire [63:0] f_taker,f_maker,r_order;
    wire f_sell,r_sell;wire [P-1:0] f_price,r_price;
    wire [Q-1:0] f_quantity,f_taker_remaining,f_maker_remaining,r_remaining,r_filled,r_cancelled;
    wire [31:0] f_index,r_fills,r_live;
    wire [T-1:0] f_tag,r_tag;wire [2:0] r_op;wire [3:0] r_status;
    price_time_order_matcher #(.ORDERS(N),.PRICE_W(P),.QTY_W(Q),.TAG_W(T)) dut(.*);
    integer fd,rc,commands=0,fill_count=0,holds=0,blocked=0,cycles=0,reset_probes=0;
    integer e_op,e_status,e_sell,e_live,e_fills;
    reg [63:0] e_order;
    reg [P-1:0] e_price;reg [Q-1:0] e_remaining,e_filled,e_cancelled;
    reg [T-1:0] e_tag;
    reg [63:0] ef_taker,ef_maker;integer ef_sell,ef_index;
    reg [P-1:0] ef_price;reg [Q-1:0] ef_quantity,ef_tr,ef_mr;reg [T-1:0] ef_tag;
    reg [1023:0] vectors;
    reg [511:0] held;
    integer k,want_fills,more;
    always @(posedge clk) begin cycles=cycles+1;if(cycles>500000) $fatal(1,"TB cycle bound");end
    task automatic reset_epoch;
        begin
            rst_n=0;c_valid=0;f_ready=0;r_ready=0;
            repeat(3) begin @(negedge clk);if(c_ready||f_valid||r_valid) $fatal(1,"reset public valid/ready");end
            rst_n=1;
            while(!c_ready) @(negedge clk);
            if(r_live!=0 || faulted) $fatal(1,"reset did not empty epoch");
        end
    endtask
    task automatic offer(input [2:0] op,input [63:0] id,input sell,
        input [P-1:0] price,input [Q-1:0] quantity);
        begin
            @(negedge clk);c_op=op;c_order=id;c_sell=sell;c_price=price;c_quantity=quantity;c_tag=0;c_valid=1;
            do @(posedge clk);while(!c_ready);
            @(negedge clk);c_valid=0;
        end
    endtask
    task automatic simple_rest;
        begin
            offer(0,64'd77,1'b1,{P{1'b1}},{Q{1'b1}});
            while(!r_valid) @(negedge clk);
            if(r_status!=0 || r_live!=1 || r_remaining!={Q{1'b1}}) $fatal(1,"reset fixture seed");
            r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
        end
    endtask
    task automatic check_empty_query;
        begin
            offer(2,64'd77,0,0,0);
            while(!r_valid) @(negedge clk);
            if(r_status!=5 || r_live!=0 || r_remaining!=0) $fatal(1,"stale order after reset");
            r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
        end
    endtask
    task automatic read_header;
        begin
            // All fscanf targets are scalar; no dynamic array element targets.
            rc=$fscanf(fd,"%d %h %d %h %h %h %d %d %h %d %h %h %h %h %d %h %d\n",
                c_op,c_order,c_sell,c_price,c_quantity,c_tag,e_op,e_status,e_order,e_sell,
                e_price,e_remaining,e_filled,e_cancelled,e_fills,e_tag,e_live);
            if(rc==-1 && $feof(fd)) more=0;
            else if(rc!=17) $fatal(1,"bad command vector rc=%0d",rc);
            else more=1;
        end
    endtask
    function automatic [511:0] response_pack;
        input dummy;
        response_pack={r_op,r_status,r_order,r_sell,r_price,r_remaining,r_filled,
            r_cancelled,r_fills,r_tag,r_live,faulted};
    endfunction
    function automatic [511:0] fill_pack;
        input dummy;
        fill_pack={f_taker,f_maker,f_sell,f_price,f_quantity,f_taker_remaining,
            f_maker_remaining,f_index,f_tag};
    endfunction
    initial begin
        if(!$value$plusargs("vectors=%s",vectors)) $fatal(1,"missing vectors");
        reset_epoch();
        // Cancellation at actual hash/RAM read ownership and held outputs.
        simple_rest();offer(2,77,0,0,0);
        while(dut.state!=3) @(negedge clk);
        reset_epoch();reset_probes=reset_probes+1;check_empty_query();
        simple_rest();offer(2,77,0,0,0);
        while(dut.state!=5) @(negedge clk);
        reset_epoch();reset_probes=reset_probes+1;check_empty_query();
        simple_rest();offer(1,77,0,0,0);
        while(!r_valid) @(negedge clk);
        reset_epoch();reset_probes=reset_probes+1;check_empty_query();
        if(N>1) begin
            simple_rest();offer(0,88,0,{P{1'b1}},1);
            while(!f_valid) @(negedge clk);
            if(f_maker!=77 || f_quantity!=1) $fatal(1,"reset fill fixture");
            reset_epoch();reset_probes=reset_probes+1;check_empty_query();
        end else begin
            simple_rest();offer(0,88,0,{P{1'b1}},1);
            while(!r_valid) @(negedge clk);
            if(r_status!=4) $fatal(1,"singleton capacity policy");
            reset_epoch();reset_probes=reset_probes+1;check_empty_query();
        end
        offer(0,99,1,{P{1'b1}},1);
        while(dut.state!=12) @(negedge clk);
        reset_epoch();reset_probes=reset_probes+1;check_empty_query();
        if(N>=3 && Q>=2) begin
            offer(0,77,1,{P{1'b1}},1);
            while(!r_valid) @(negedge clk);r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
            offer(0,78,1,{P{1'b1}},1);
            while(!r_valid) @(negedge clk);r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
            offer(0,88,0,{P{1'b1}},2);
            while(!f_valid) @(negedge clk);
            if(f_maker!=77 || f_quantity!=1 || f_taker_remaining!=1) $fatal(1,"accepted prefix fixture");
            f_ready=1;@(posedge clk);@(negedge clk);f_ready=0;
            while(!f_valid) @(negedge clk);
            if(f_maker!=78 || f_quantity!=1) $fatal(1,"prefix suffix fixture");
        end else begin
            simple_rest();offer(2,77,0,0,0);while(!r_valid) @(negedge clk);
        end
        reset_epoch();reset_probes=reset_probes+1;check_empty_query();
        reset_epoch();
        fd=$fopen(vectors,"r");if(!fd) $fatal(1,"open vectors");
        @(negedge clk);read_header();
        while(more) begin
            c_valid=1;
            do @(posedge clk);while(!c_ready);
            @(negedge clk);c_valid=0;commands=commands+1;
            want_fills=e_fills;
            for(k=0;k<want_fills;k=k+1) begin
                rc=$fscanf(fd,"%h %h %d %h %h %h %h %d %h\n",
                    ef_taker,ef_maker,ef_sell,ef_price,ef_quantity,ef_tr,ef_mr,ef_index,ef_tag);
                if(rc!=9) $fatal(1,"bad fill vector");
                while(!f_valid) begin @(negedge clk);if(r_valid||c_ready) $fatal(1,"early completion/admission");end
                if(f_taker!==ef_taker || f_maker!==ef_maker || f_sell!==ef_sell[0] || f_price!==ef_price ||
                    f_quantity!==ef_quantity || f_taker_remaining!==ef_tr || f_maker_remaining!==ef_mr ||
                    f_index!==ef_index || f_tag!==ef_tag || faulted) $fatal(1,"fill mismatch command=%0d fill=%0d",commands,k);
                held=fill_pack(0);
                repeat(4) begin @(negedge clk);holds=holds+1;
                    if(!f_valid || fill_pack(0)!==held || c_ready || r_valid) $fatal(1,"fill hold/owner");end
                f_ready=1;@(posedge clk);@(negedge clk);f_ready=0;fill_count=fill_count+1;
            end
            while(!r_valid) begin @(negedge clk);if(f_valid) $fatal(1,"extra fill");end
            if(r_op!==e_op[2:0] || r_status!==e_status[3:0] || r_order!==e_order ||
                r_sell!==e_sell[0] || r_price!==e_price || r_remaining!==e_remaining ||
                r_filled!==e_filled || r_cancelled!==e_cancelled || r_fills!==e_fills ||
                r_tag!==e_tag || r_live!==e_live || faulted) $fatal(1,"response mismatch command=%0d status=%0d expected=%0d",commands,r_status,e_status);
            held=response_pack(0);
            // Prefetch and retain the real next command while the owner is stalled.
            read_header();c_valid=(more!=0);
            repeat(5) begin @(negedge clk);holds=holds+1;if(c_valid) blocked=blocked+1;
                if(!r_valid || response_pack(0)!==held || c_ready || f_valid) $fatal(1,"response hold/real next offer");end
            r_ready=1;@(posedge clk);if(c_ready) $fatal(1,"same-edge admission");
            @(negedge clk);r_ready=0;
        end
        c_valid=0;$fclose(fd);repeat(3) @(negedge clk);
        if(f_valid||r_valid||r_live!=0||faulted) $fatal(1,"final state");
        $display("B49_ORDER_SIM_PASS commands=%0d fills=%0d holds=%0d blocked=%0d reset_probes=%0d cycles=%0d",commands,fill_count,holds,blocked,reset_probes,cycles);
        $finish;
    end
endmodule
