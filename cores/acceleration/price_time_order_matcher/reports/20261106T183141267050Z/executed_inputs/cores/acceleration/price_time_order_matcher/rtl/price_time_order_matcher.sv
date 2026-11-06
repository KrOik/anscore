// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module price_time_order_matcher #(
    parameter integer ORDERS=16,
    parameter integer PRICE_W=32,
    parameter integer QTY_W=32,
    parameter integer TAG_W=8,
    localparam integer IW=(ORDERS<2)?1:$clog2(ORDERS),
    localparam integer CW=(ORDERS<2)?1:$clog2(ORDERS+1),
    localparam integer HASH_SLOTS=(ORDERS<2)?1:(1<<$clog2(ORDERS)),
    localparam integer RAW_W=QTY_W+PRICE_W+1+64+IW+1,
    localparam integer ROW_W=8*((RAW_W+7)/8)
)(
    input wire clk,rst_n,
    input wire c_valid,
    output wire c_ready,
    input wire [2:0] c_op,
    input wire [63:0] c_order,
    input wire c_sell,
    input wire [PRICE_W-1:0] c_price,
    input wire [QTY_W-1:0] c_quantity,
    input wire [TAG_W-1:0] c_tag,
    output wire f_valid,
    input wire f_ready,
    output reg [63:0] f_taker,f_maker,
    output reg f_sell,
    output reg [PRICE_W-1:0] f_price,
    output reg [QTY_W-1:0] f_quantity,f_taker_remaining,f_maker_remaining,
    output reg [31:0] f_index,
    output reg [TAG_W-1:0] f_tag,
    output wire r_valid,
    input wire r_ready,
    output reg [2:0] r_op,
    output reg [3:0] r_status,
    output reg [63:0] r_order,
    output reg r_sell,
    output reg [PRICE_W-1:0] r_price,
    output reg [QTY_W-1:0] r_remaining,r_filled,r_cancelled,
    output reg [31:0] r_fills,
    output reg [TAG_W-1:0] r_tag,
    output wire [31:0] r_live,
    output wire busy,
    output reg faulted
);
    generate if (ORDERS<1 || ORDERS>32 || PRICE_W<1 || PRICE_W>32 ||
        QTY_W<1 || QTY_W>32 || TAG_W<1 || TAG_W>32) begin: invalid_parameters
        price_time_order_matcher_invalid_parameters__see_README bad();
    end endgenerate
    localparam [3:0] OK=0,BAD_OP=1,BAD_QUANTITY=2,DUPLICATE=3,FULL=4,
        NOT_FOUND=5,FAULTED=6,BACKEND_FAULT=7;
    localparam [5:0] IDLE=0,RESPONSE=1,HASH_SEND=2,HASH_WAIT=3,
        RAM_SEND=4,RAM_WAIT=5,LOOKUP_DONE=6,MATCH_BEGIN=7,SCAN_ROW=8,
        MATCH_PICK=9,FILL=10,REST_HASH=11,REST_WRITTEN=12,REST_TAIL=13,
        REST_COMMIT=14,READ_ORDER=15,CANCEL_BEGIN=16,CANCEL_SCAN=17,
        REMOVE_HASH=18,REMOVE_PREV=19,REMOVE_COMMIT=20,CLEAR_DONE=21;
    localparam integer SELL_BIT=QTY_W+PRICE_W;
    localparam integer ID_LOW=SELL_BIT+1;
    localparam integer NEXT_LOW=ID_LOW+64;
    localparam integer NEXT_VALID=NEXT_LOW+IW;
    reg [5:0] state,ram_after,hash_after;
    reg [ORDERS-1:0] live;
    reg [CW-1:0] count,scan_count;
    reg head_valid;
    reg [IW-1:0] head,tail,reserved,scan_slot,scan_prev,best_slot,best_prev,
        remove_slot,remove_prev,target;
    reg scan_prev_valid,best_valid,best_prev_valid,remove_prev_valid,remove_to_fill;
    reg [ROW_W-1:0] row_q,best_row,remove_row;
    reg [63:0] order_q;
    reg sell_q;
    reg [PRICE_W-1:0] price_q;
    reg [QTY_W-1:0] remaining,filled;
    reg [31:0] fills;
    reg [TAG_W-1:0] tag_q;
    reg free_found;
    reg [IW-1:0] free_slot;
    integer alloc;
    always @* begin
        free_found=1'b0;free_slot={IW{1'b0}};
        for (alloc=0;alloc<ORDERS;alloc=alloc+1)
            if (!free_found && !live[alloc]) begin
                free_found=1'b1;free_slot=alloc[IW-1:0];
            end
    end
    function automatic [ROW_W-1:0] pack_row(
        input nv,input [IW-1:0] ns,input [63:0] id,input side,
        input [PRICE_W-1:0] price,input [QTY_W-1:0] quantity);
        pack_row={{(ROW_W-RAW_W){1'b0}},nv,ns,id,side,price,quantity};
    endfunction
    function automatic [ROW_W-1:0] with_next(
        input [ROW_W-1:0] row,input nv,input [IW-1:0] ns);
        begin with_next=row;with_next[NEXT_VALID]=nv;with_next[NEXT_LOW+:IW]=ns;end
    endfunction
    function automatic [ROW_W-1:0] with_quantity(
        input [ROW_W-1:0] row,input [QTY_W-1:0] quantity);
        begin with_quantity=row;with_quantity[QTY_W-1:0]=quantity;end
    endfunction
    wire row_sell=row_q[SELL_BIT];
    wire [PRICE_W-1:0] row_price=row_q[QTY_W+:PRICE_W];
    wire [QTY_W-1:0] best_quantity=best_row[QTY_W-1:0];
    wire [QTY_W-1:0] match_quantity=(remaining<best_quantity)?remaining:best_quantity;
    wire crosses=(row_sell!=sell_q) && (sell_q?(row_price>=price_q):(row_price<=price_q));
    wire better=!best_valid || (sell_q?(row_price>best_row[QTY_W+:PRICE_W]):
        (row_price<best_row[QTY_W+:PRICE_W]));

    reg [1:0] hash_op;
    reg [63:0] hash_key;
    reg [IW-1:0] hash_value;
    wire hash_ready,hash_valid,hash_found,hash_inserted;
    wire [1:0] hash_status;
    wire [IW-1:0] hash_old;
    reg [1:0] hs;
    reg hf,hi;
    reg [IW-1:0] hv;
    ram_hash_table #(.SLOTS(HASH_SLOTS),.KEY_W(64),.VALUE_W(IW),.TAG_W(1)) id_index (
        .clk(clk),.rst(!rst_n),.c_valid(state==HASH_SEND && rst_n),.c_ready(hash_ready),
        .c_op(hash_op),.c_key(hash_key),.c_value(hash_value),.c_tag(1'b0),
        .r_valid(hash_valid),.r_ready(state==HASH_WAIT && rst_n),.r_status(hash_status),
        .r_found(hash_found),.r_inserted(hash_inserted),.r_old_value(hash_old),
        .r_count(),.r_tag());
    reg ram_write;
    reg [IW-1:0] ram_address;
    reg [ROW_W-1:0] ram_data;
    wire ram_ready,ram_valid,ram_error;
    wire [ROW_W-1:0] ram_result;
    cip_sync_sp_ram #(.DATA_WIDTH(ROW_W),.ADDR_WIDTH(IW),.DEPTH(ORDERS)) rows (
        .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
        .req_valid(state==RAM_SEND && rst_n),.req_ready(ram_ready),.req_write(ram_write),
        .req_addr(ram_address),.req_wdata(ram_data),.req_wstrb({(ROW_W/8){1'b1}}),
        .rsp_valid(ram_valid),.rsp_ready(state==RAM_WAIT && rst_n),
        .rsp_rdata(ram_result),.rsp_error(ram_error));
    assign c_ready=rst_n && state==IDLE && hash_ready;
    assign f_valid=rst_n && state==FILL;
    assign r_valid=rst_n && state==RESPONSE;
    assign r_live={{(32-CW){1'b0}},count};
    assign busy=rst_n && state!=IDLE;
    task automatic hash_request(input [1:0] op,input [63:0] key,
        input [IW-1:0] value,input [5:0] after_state);
        begin hash_op<=op;hash_key<=key;hash_value<=value;hash_after<=after_state;state<=HASH_SEND;end
    endtask
    task automatic ram_request(input wr,input [IW-1:0] addr,
        input [ROW_W-1:0] data,input [5:0] after_state);
        begin ram_write<=wr;ram_address<=addr;ram_data<=data;ram_after<=after_state;state<=RAM_SEND;end
    endtask
    task automatic backend_error;
        begin faulted<=1'b1;r_status<=BACKEND_FAULT;r_sell<=0;r_price<=0;
            r_remaining<=0;r_filled<=0;r_cancelled<=0;r_fills<=0;state<=RESPONSE;end
    endtask
    task automatic complete_new;
        begin r_remaining<=remaining;r_filled<=filled;r_fills<=fills;state<=RESPONSE;end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE;live<=0;count<=0;head_valid<=0;head<=0;tail<=0;faulted<=0;
            r_op<=0;r_status<=0;r_order<=0;r_sell<=0;r_price<=0;r_remaining<=0;
            r_filled<=0;r_cancelled<=0;r_fills<=0;r_tag<=0;
            f_taker<=0;f_maker<=0;f_sell<=0;f_price<=0;f_quantity<=0;
            f_taker_remaining<=0;f_maker_remaining<=0;f_index<=0;f_tag<=0;
        end else case (state)
            IDLE: if (c_valid && c_ready) begin
                r_op<=c_op;r_order<=c_order;r_tag<=c_tag;r_status<=OK;
                r_sell<=0;r_price<=0;r_remaining<=0;r_filled<=0;r_cancelled<=0;r_fills<=0;
                order_q<=c_order;sell_q<=c_sell;price_q<=c_price;
                remaining<=c_quantity;filled<=0;fills<=0;tag_q<=c_tag;
                if (c_op>3) begin r_status<=BAD_OP;state<=RESPONSE;end
                else if (c_op==3) hash_request(3,64'b0,{IW{1'b0}},CLEAR_DONE);
                else if (faulted) begin r_status<=FAULTED;state<=RESPONSE;end
                else if (c_op==0 && c_quantity==0) begin r_status<=BAD_QUANTITY;state<=RESPONSE;end
                else hash_request(0,c_order,{IW{1'b0}},LOOKUP_DONE);
            end
            HASH_SEND: if (hash_ready) state<=HASH_WAIT;
            HASH_WAIT: if (hash_valid) begin hs<=hash_status;hf<=hash_found;hi<=hash_inserted;hv<=hash_old;state<=hash_after;end
            RAM_SEND: if (ram_ready) state<=RAM_WAIT;
            RAM_WAIT: if (ram_valid) begin
                if (ram_error) backend_error();
                else begin row_q<=ram_result;state<=ram_after;end
            end
            LOOKUP_DONE: begin
                if (r_op==0) begin
                    if (hs==0 && hf) begin r_status<=DUPLICATE;state<=RESPONSE;end
                    else if (hs!=1 || hf) backend_error();
                    else if (!free_found || count==ORDERS) begin r_status<=FULL;state<=RESPONSE;end
                    else begin reserved<=free_slot;r_sell<=sell_q;r_price<=price_q;state<=MATCH_BEGIN;end
                end else if (hs==1 && !hf) begin r_status<=NOT_FOUND;state<=RESPONSE;end
                else if (hs!=0 || !hf || hv>=ORDERS) backend_error();
                else if (!live[hv]) backend_error();
                else begin target<=hv;ram_request(0,hv,{ROW_W{1'b0}},READ_ORDER);end
            end
            MATCH_BEGIN: begin
                best_valid<=0;scan_prev_valid<=0;scan_count<=0;
                if (head_valid) begin scan_slot<=head;ram_request(0,head,{ROW_W{1'b0}},SCAN_ROW);end
                else hash_request(1,order_q,reserved,REST_HASH);
            end
            SCAN_ROW: begin
                if (scan_slot>=ORDERS || !live[scan_slot] || scan_count>=ORDERS || row_q[QTY_W-1:0]==0) backend_error();
                else begin
                    if (crosses && better) begin best_valid<=1;best_row<=row_q;best_slot<=scan_slot;
                        best_prev<=scan_prev;best_prev_valid<=scan_prev_valid;end
                    scan_count<=scan_count+1'b1;
                    if (row_q[NEXT_VALID]) begin
                        if (row_q[NEXT_LOW+:IW]>=ORDERS) backend_error();
                        else begin scan_prev<=scan_slot;scan_prev_valid<=1;
                            scan_slot<=row_q[NEXT_LOW+:IW];ram_request(0,row_q[NEXT_LOW+:IW],{ROW_W{1'b0}},SCAN_ROW);end
                    end else state<=MATCH_PICK;
                end
            end
            MATCH_PICK: begin
                if (!best_valid) hash_request(1,order_q,reserved,REST_HASH);
                else begin
                    f_taker<=order_q;f_maker<=best_row[ID_LOW+:64];f_sell<=sell_q;
                    f_price<=best_row[QTY_W+:PRICE_W];f_quantity<=match_quantity;
                    f_taker_remaining<=remaining-match_quantity;f_maker_remaining<=best_quantity-match_quantity;
                    f_index<=fills;f_tag<=tag_q;remaining<=remaining-match_quantity;
                    filled<=filled+match_quantity;fills<=fills+1'b1;
                    if (best_quantity>match_quantity)
                        ram_request(1,best_slot,with_quantity(best_row,best_quantity-match_quantity),FILL);
                    else begin remove_slot<=best_slot;remove_prev<=best_prev;
                        remove_prev_valid<=best_prev_valid;remove_row<=best_row;remove_to_fill<=1;
                        hash_request(2,best_row[ID_LOW+:64],{IW{1'b0}},REMOVE_HASH);end
                end
            end
            FILL: if (f_ready) begin
                if (remaining==0) complete_new();else state<=MATCH_BEGIN;
            end
            REST_HASH: begin
                if (hs!=0 || hf || !hi) backend_error();
                else ram_request(1,reserved,pack_row(0,{IW{1'b0}},order_q,sell_q,price_q,remaining),REST_WRITTEN);
            end
            REST_WRITTEN: begin
                if (head_valid) ram_request(0,tail,{ROW_W{1'b0}},REST_TAIL);
                else state<=REST_COMMIT;
            end
            REST_TAIL: begin
                if (!live[tail] || row_q[NEXT_VALID]) backend_error();
                else ram_request(1,tail,with_next(row_q,1,reserved),REST_COMMIT);
            end
            REST_COMMIT: begin
                live[reserved]<=1;count<=count+1'b1;tail<=reserved;
                if (!head_valid) begin head<=reserved;head_valid<=1;end
                complete_new();
            end
            READ_ORDER: begin
                if (row_q[ID_LOW+:64]!=order_q || row_q[QTY_W-1:0]==0) backend_error();
                else begin
                    r_sell<=row_q[SELL_BIT];r_price<=row_q[QTY_W+:PRICE_W];
                    if (r_op==2) begin r_remaining<=row_q[QTY_W-1:0];state<=RESPONSE;end
                    else begin remove_row<=row_q;remove_slot<=target;remove_to_fill<=0;
                        r_cancelled<=row_q[QTY_W-1:0];state<=CANCEL_BEGIN;end
                end
            end
            CANCEL_BEGIN: begin
                scan_count<=0;scan_prev_valid<=0;scan_slot<=head;
                if (!head_valid) backend_error();
                else if (head==remove_slot) begin remove_prev_valid<=0;
                    hash_request(2,order_q,{IW{1'b0}},REMOVE_HASH);end
                else ram_request(0,head,{ROW_W{1'b0}},CANCEL_SCAN);
            end
            CANCEL_SCAN: begin
                if (scan_slot>=ORDERS || !live[scan_slot] || scan_count>=ORDERS || !row_q[NEXT_VALID]) backend_error();
                else if (row_q[NEXT_LOW+:IW]==remove_slot) begin
                    remove_prev<=scan_slot;remove_prev_valid<=1;
                    hash_request(2,order_q,{IW{1'b0}},REMOVE_HASH);
                end else if (row_q[NEXT_LOW+:IW]>=ORDERS) backend_error();
                else begin scan_count<=scan_count+1'b1;scan_slot<=row_q[NEXT_LOW+:IW];
                    ram_request(0,row_q[NEXT_LOW+:IW],{ROW_W{1'b0}},CANCEL_SCAN);end
            end
            REMOVE_HASH: begin
                if (hs!=0 || !hf || hv!=remove_slot) backend_error();
                else if (remove_prev_valid) ram_request(0,remove_prev,{ROW_W{1'b0}},REMOVE_PREV);
                else begin head_valid<=remove_row[NEXT_VALID];head<=remove_row[NEXT_LOW+:IW];state<=REMOVE_COMMIT;end
            end
            REMOVE_PREV: begin
                if (!live[remove_prev] || !row_q[NEXT_VALID] || row_q[NEXT_LOW+:IW]!=remove_slot) backend_error();
                else ram_request(1,remove_prev,with_next(row_q,remove_row[NEXT_VALID],remove_row[NEXT_LOW+:IW]),REMOVE_COMMIT);
            end
            REMOVE_COMMIT: begin
                live[remove_slot]<=0;count<=count-1'b1;
                if (tail==remove_slot) tail<=remove_prev;
                if (count==1) head_valid<=0;
                state<=remove_to_fill?FILL:RESPONSE;
            end
            CLEAR_DONE: begin
                if (hs!=0) backend_error();
                else begin live<=0;count<=0;head_valid<=0;head<=0;tail<=0;faulted<=0;state<=RESPONSE;end
            end
            RESPONSE: if (r_ready) state<=IDLE;
            default: backend_error();
        endcase
    end
endmodule
