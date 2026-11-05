// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_price_level_order_book;
    parameter integer LEVELS=5,PRICE_W=9,QTY_W=7,TAG_W=8;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg c_valid=0,r_ready=0;
    reg [3:0] c_op=0;
    reg c_side=0;
    reg [PRICE_W-1:0] c_price=0;
    reg [QTY_W-1:0] c_quantity=0;
    reg [31:0] c_rank=0;
    reg [TAG_W-1:0] c_tag=0;
    wire c_ready,r_valid,r_side,r_found;
    wire [3:0] r_op;
    wire [2:0] r_status;
    wire [PRICE_W-1:0] r_price;
    wire [QTY_W-1:0] r_quantity,r_previous;
    wire [31:0] r_bid_levels,r_ask_levels;
    wire [TAG_W-1:0] r_tag;
    price_level_order_book #(.LEVELS(LEVELS),.PRICE_W(PRICE_W),.QTY_W(QTY_W),.TAG_W(TAG_W)) dut(.*);
    integer fd,rc,commands=0,stalls=0,reset_cases=0,cycles=0,bound,j;
    reg [1023:0] vectors;
    reg [63:0] kind,op,side,price,quantity,rank,tag,status,found,ep,eqty,previous,bids,asks;
    localparam integer RESPONSE_W=4+1+3+1+PRICE_W+2*QTY_W+64+TAG_W;
    reg [RESPONSE_W-1:0] held;
    wire [RESPONSE_W-1:0] actual={r_op,r_side,r_status,r_found,r_price,r_quantity,r_previous,r_bid_levels,r_ask_levels,r_tag};
    task reset_book;
        begin
            @(negedge clk);rst_n=0;c_valid=0;r_ready=0;
            #1;if(c_ready||r_valid||r_bid_levels||r_ask_levels) $fatal(1,"async reset qualification");
            repeat(2) @(negedge clk);rst_n=1;
            @(negedge clk);
            if(!c_ready||r_valid) $fatal(1,"reset ownership release");
        end
    endtask
    task send(input [3:0] operation,input s,input [PRICE_W-1:0] p,input [QTY_W-1:0] q,input [31:0] rk,input [TAG_W-1:0] t);
        begin
            @(negedge clk);c_valid=1;c_op=operation;c_side=s;c_price=p;c_quantity=q;c_rank=rk;c_tag=t;
            @(posedge clk);while(!c_ready) @(posedge clk);
            @(negedge clk);c_valid=0;
        end
    endtask
    task wait_response;
        begin
            bound=0;
            while(!r_valid) begin
                @(negedge clk);bound=bound+1;
                if(bound>5000) $fatal(1,"response deadline");
            end
        end
    endtask
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>1000000) $fatal(1,"global finite watchdog");
    end
    initial begin
        if(!$value$plusargs("vectors=%s",vectors)) $fatal(1,"missing vectors");
        fd=$fopen(vectors,"r");if(!fd) $fatal(1,"missing vector file");
        reset_book();
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                        kind,op,side,price,quantity,rank,tag,status,found,ep,eqty,previous,bids,asks);
            if(rc!=14) $fatal(1,"malformed vector count %0d",rc);
            if(kind==0) begin
                repeat(commands%3) @(negedge clk);
                send(op[3:0],side[0],price[PRICE_W-1:0],quantity[QTY_W-1:0],rank[31:0],tag[TAG_W-1:0]);
                wait_response();
                if(r_op!==op[3:0]||r_side!==side[0]||r_tag!==tag[TAG_W-1:0]||
                   r_status!==status[2:0]||r_found!==found[0]||r_price!==ep[PRICE_W-1:0]||
                   r_quantity!==eqty[QTY_W-1:0]||r_previous!==previous[QTY_W-1:0]||
                   r_bid_levels!==bids[31:0]||r_ask_levels!==asks[31:0])
                    $fatal(1,"cmd%0d op%0d side%0d price%0d qty%0d: status%0d/%0d found%0d/%0d price%0d/%0d qty%0d/%0d prev%0d/%0d bids%0d/%0d asks%0d/%0d",commands,op,side,price,quantity,r_status,status,r_found,found,r_price,ep,r_quantity,eqty,r_previous,previous,r_bid_levels,bids,r_ask_levels,asks);
                held=actual;
                // Offer a stable next command while the prior response is held.
                c_valid=1;c_op=4;c_side=!side[0];c_price=0;c_quantity=0;c_rank=0;c_tag=0;
                for(j=0;j<3+commands%3;j=j+1) begin
                    @(negedge clk);
                    if(!r_valid||actual!==held||c_ready) $fatal(1,"held response/next command ownership");
                    stalls=stalls+1;
                end
                c_valid=0;r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
                if(r_valid) $fatal(1,"duplicate response");
                commands=commands+1;
            end else if(kind==1) begin reset_book();reset_cases=reset_cases+1;end
            else if(kind==2) begin
                send(0,0,{PRICE_W{1'b1}},{QTY_W{1'b1}},0,0);
                repeat(5) @(negedge clk);reset_book();reset_cases=reset_cases+1;
            end else if(kind==3) begin
                send(0,1,{PRICE_W{1'b1}},{QTY_W{1'b1}},0,0);
                wait_response();repeat(4) @(negedge clk);reset_book();reset_cases=reset_cases+1;
            end else $fatal(1,"unknown vector kind");
        end
        $fclose(fd);
        if(commands<30||stalls==0||reset_cases!=3) $fatal(1,"vacuous coverage");
        $display("PASS price_level_order_book L=%0d P=%0d Q=%0d T=%0d commands=%0d holds=%0d reset_cases=%0d cycles=%0d",LEVELS,PRICE_W,QTY_W,TAG_W,commands,stalls,reset_cases,cycles);
        $finish;
    end
endmodule
