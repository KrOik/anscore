// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module two_client_limit_matcher(
    input wire clk,rst_n,
    input wire a_valid,output wire a_ready,input wire [2:0] a_op,
    input wire [63:0] a_order,input wire a_sell,input wire [31:0] a_price,a_quantity,
    input wire [7:0] a_tag,
    input wire b_valid,output wire b_ready,input wire [2:0] b_op,
    input wire [63:0] b_order,input wire b_sell,input wire [31:0] b_price,b_quantity,
    input wire [7:0] b_tag,
    output wire a_r_valid,input wire a_r_ready,
    output wire b_r_valid,input wire b_r_ready,
    output wire [2:0] r_op,output wire [3:0] r_status,output wire [63:0] r_order,
    output wire r_sell,output wire [31:0] r_price,r_remaining,r_filled,r_cancelled,r_fills,
    output wire [7:0] r_tag,output wire [31:0] r_live,
    output wire f_valid,input wire f_ready,output wire f_client,
    output wire [63:0] f_taker,f_maker,output wire f_sell,
    output wire [31:0] f_price,f_quantity,f_taker_remaining,f_maker_remaining,f_index,
    output wire [7:0] f_tag,output wire busy,faulted
);
    reg owner_valid,owner,prefer_b;
    wire select_b=b_valid && (!a_valid || prefer_b);
    wire core_ready,core_r_valid;
    wire core_valid=!owner_valid && (a_valid || b_valid);
    wire core_r_ready=owner_valid && (owner?b_r_ready:a_r_ready);
    assign a_ready=!owner_valid && !select_b && core_ready;
    assign b_ready=!owner_valid && select_b && core_ready;
    assign a_r_valid=owner_valid && !owner && core_r_valid;
    assign b_r_valid=owner_valid && owner && core_r_valid;
    assign f_client=owner;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin owner_valid<=0;owner<=0;prefer_b<=0;end
        else begin
            if (core_valid && core_ready) begin
                owner_valid<=1;owner<=select_b;prefer_b<=!select_b;
            end
            if (core_r_valid && core_r_ready) owner_valid<=0;
        end
    end
    price_time_order_matcher #(.ORDERS(8),.PRICE_W(32),.QTY_W(32),.TAG_W(8)) book (
        .clk(clk),.rst_n(rst_n),.c_valid(core_valid),.c_ready(core_ready),
        .c_op(select_b?b_op:a_op),.c_order(select_b?b_order:a_order),
        .c_sell(select_b?b_sell:a_sell),.c_price(select_b?b_price:a_price),
        .c_quantity(select_b?b_quantity:a_quantity),.c_tag(select_b?b_tag:a_tag),
        .f_valid(f_valid),.f_ready(f_ready),.f_taker(f_taker),.f_maker(f_maker),
        .f_sell(f_sell),.f_price(f_price),.f_quantity(f_quantity),
        .f_taker_remaining(f_taker_remaining),.f_maker_remaining(f_maker_remaining),
        .f_index(f_index),.f_tag(f_tag),.r_valid(core_r_valid),.r_ready(core_r_ready),
        .r_op(r_op),.r_status(r_status),.r_order(r_order),.r_sell(r_sell),.r_price(r_price),
        .r_remaining(r_remaining),.r_filled(r_filled),.r_cancelled(r_cancelled),
        .r_fills(r_fills),.r_tag(r_tag),.r_live(r_live),.busy(busy),.faulted(faulted));
endmodule
