// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_two_client_limit_matcher;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,a_valid=0,b_valid=0,a_r_ready=0,b_r_ready=0,f_ready=0;
    reg [2:0] a_op=0,b_op=0;reg [63:0] a_order=0,b_order=0;
    reg a_sell=0,b_sell=0;reg [31:0] a_price=0,b_price=0,a_quantity=0,b_quantity=0;
    reg [7:0] a_tag=0,b_tag=0;
    wire a_ready,b_ready,a_r_valid,b_r_valid,f_valid,f_client,busy,faulted;
    wire [2:0] r_op;wire [3:0] r_status;wire [63:0] r_order,f_taker,f_maker;
    wire r_sell,f_sell;wire [31:0] r_price,r_remaining,r_filled,r_cancelled,r_fills,r_live;
    wire [31:0] f_price,f_quantity,f_taker_remaining,f_maker_remaining,f_index;
    wire [7:0] r_tag,f_tag;
    two_client_limit_matcher dut(.*);
    integer cycles=0,commands=0,fills=0,holds=0;
    reg [511:0] saved;
    always @(posedge clk) begin cycles=cycles+1;if(cycles>20000) $fatal(1,"example bound");end
    task automatic send(input client,input [2:0] op,input [63:0] id,input sell,
        input [31:0] price,input [31:0] qty,input [7:0] tag);
        begin
            @(negedge clk);
            if(client) begin b_valid=1;b_op=op;b_order=id;b_sell=sell;b_price=price;b_quantity=qty;b_tag=tag;end
            else begin a_valid=1;a_op=op;a_order=id;a_sell=sell;a_price=price;a_quantity=qty;a_tag=tag;end
            do @(posedge clk);while(!(client?b_ready:a_ready));
            @(negedge clk);if(client)b_valid=0;else a_valid=0;
        end
    endtask
    task automatic response(input client,input [2:0] op,input [3:0] status,input [63:0] id,
        input sell,input [31:0] price,input [31:0] remain,input [31:0] filled,
        input [31:0] cancelled,input [31:0] nf,input [7:0] tag,input [31:0] live);
        begin
            while(!(a_r_valid||b_r_valid)) @(negedge clk);
            if((client?a_r_valid:b_r_valid) || !(client?b_r_valid:a_r_valid)) $fatal(1,"wrong completion client");
            if(r_op!==op||r_status!==status||r_order!==id||r_sell!==sell||r_price!==price||
                r_remaining!==remain||r_filled!==filled||r_cancelled!==cancelled||r_fills!==nf||
                r_tag!==tag||r_live!==live||faulted) $fatal(1,"example completion %0d",commands);
            saved={a_r_valid,b_r_valid,r_op,r_status,r_order,r_sell,r_price,r_remaining,r_filled,r_cancelled,r_fills,r_tag,r_live};
            repeat(4) begin @(negedge clk);holds=holds+1;
                if(a_ready||b_ready||saved!=={a_r_valid,b_r_valid,r_op,r_status,r_order,r_sell,r_price,r_remaining,r_filled,r_cancelled,r_fills,r_tag,r_live}) $fatal(1,"example held completion");end
            if(client)b_r_ready=1;else a_r_ready=1;
            @(posedge clk);@(negedge clk);a_r_ready=0;b_r_ready=0;commands=commands+1;
        end
    endtask
    task automatic fill(input client,input [63:0] taker,input [63:0] maker,
        input [31:0] price,input [31:0] qty,input [31:0] tr,input [31:0] mr,
        input [31:0] index,input [7:0] tag);
        begin
            while(!f_valid) @(negedge clk);
            if(f_client!==client||f_taker!==taker||f_maker!==maker||f_sell!==0||f_price!==price||
                f_quantity!==qty||f_taker_remaining!==tr||f_maker_remaining!==mr||f_index!==index||f_tag!==tag) $fatal(1,"example maker fill");
            saved={f_client,f_taker,f_maker,f_sell,f_price,f_quantity,f_taker_remaining,f_maker_remaining,f_index,f_tag};
            repeat(3) begin @(negedge clk);holds=holds+1;
                if(!f_valid||a_ready||b_ready||a_r_valid||b_r_valid||saved!=={f_client,f_taker,f_maker,f_sell,f_price,f_quantity,f_taker_remaining,f_maker_remaining,f_index,f_tag}) $fatal(1,"example fill hold");end
            f_ready=1;@(posedge clk);@(negedge clk);f_ready=0;fills=fills+1;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        send(0,0,1,1,100,5,1);response(0,0,0,1,1,100,5,0,0,0,1,1);
        send(1,0,2,1,100,7,2);response(1,0,0,2,1,100,7,0,0,0,2,2);
        send(0,0,3,0,101,6,3);fill(0,3,1,100,5,1,0,0,3);fill(0,3,2,100,1,0,6,1,3);
        response(0,0,0,3,0,101,0,6,0,2,3,1);
        send(0,2,2,0,0,0,4);response(0,2,0,2,1,100,6,0,0,0,4,1);
        send(1,1,2,0,0,0,5);response(1,1,0,2,1,100,0,0,6,0,5,0);
        // Both real offers stay asserted; A wins after the preceding B owner.
        @(negedge clk);a_op=0;a_order=4;a_sell=1;a_price=99;a_quantity=1;a_tag=6;a_valid=1;
        b_op=0;b_order=5;b_sell=1;b_price=99;b_quantity=1;b_tag=7;b_valid=1;
        do @(posedge clk);while(!a_ready);
        if(b_ready) $fatal(1,"both clients admitted");
        @(negedge clk);a_valid=0;
        response(0,0,0,4,1,99,1,0,0,0,6,1);
        do @(posedge clk);while(!b_ready);
        @(negedge clk);b_valid=0;response(1,0,0,5,1,99,1,0,0,0,7,2);
        send(1,0,6,0,99,2,8);fill(1,6,4,99,1,1,0,0,8);fill(1,6,5,99,1,0,0,1,8);
        response(1,0,0,6,0,99,0,2,0,2,8,0);
        send(1,0,9,1,1,1,9);while(!b_r_valid) @(negedge clk);
        rst_n=0;repeat(3) begin @(negedge clk);if(a_r_valid||b_r_valid||f_valid||a_ready||b_ready) $fatal(1,"example reset");end
        rst_n=1;send(0,2,9,0,0,0,10);response(0,2,5,9,0,0,0,0,0,0,10,0);
        $display("B49_ORDER_EXAMPLE_PASS commands=%0d fills=%0d holds=%0d simultaneous=1 resets=2",commands,fills,holds);
        $finish;
    end
endmodule
