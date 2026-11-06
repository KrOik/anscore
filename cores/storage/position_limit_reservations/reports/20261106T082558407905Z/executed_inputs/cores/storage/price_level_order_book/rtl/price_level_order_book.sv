// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE composition: atomic L2 quantity operations on two ordered RAMs.
`default_nettype none
module price_level_order_book #(
    parameter integer LEVELS=16, PRICE_W=32, QTY_W=32, TAG_W=8
) (
    input wire clk, input wire rst_n,
    input wire c_valid, output wire c_ready,
    input wire [3:0] c_op, input wire c_side,
    input wire [PRICE_W-1:0] c_price,
    input wire [QTY_W-1:0] c_quantity,
    input wire [31:0] c_rank, input wire [TAG_W-1:0] c_tag,
    output wire r_valid, input wire r_ready,
    output reg [3:0] r_op, output reg r_side,
    output reg [2:0] r_status, output reg r_found,
    output reg [PRICE_W-1:0] r_price,
    output reg [QTY_W-1:0] r_quantity, r_previous,
    output wire [31:0] r_bid_levels, r_ask_levels,
    output reg [TAG_W-1:0] r_tag
);
    localparam integer CW=(LEVELS<2)?1:$clog2(LEVELS+1);
    localparam [1:0] IDLE=0,SEND=1,WAIT_REPLY=2,RESPONSE=3;
    localparam [2:0] LOOKUP=0,WRITE=1,BEST=2,DEPTH=3,CLEAR=4;
    localparam [2:0] OK=0,NOT_FOUND=1,FULL=2,BAD_QUANTITY=3,
                     OVERFLOW=4,UNDERFLOW=5,BAD_RANK=6,BAD_OP=7;
    reg [1:0] state;
    reg [2:0] phase,q_op;
    reg q_side;
    reg [PRICE_W-1:0] q_key,price;
    reg [QTY_W-1:0] q_value,quantity,new_quantity,previous;
    reg existed,depth_found;
    reg [31:0] rank;
    reg [CW-1:0] depth_seen,bid_count,ask_count;
    reg [PRICE_W-1:0] depth_price;
    reg [QTY_W-1:0] depth_quantity;
    wire [1:0] backend_ready,backend_valid;
    wire [3:0] backend_kind;
    wire [5:0] backend_status;
    wire [1:0] backend_found;
    wire [2*PRICE_W-1:0] backend_key;
    wire [2*QTY_W-1:0] backend_value;
    wire [2*CW-1:0] backend_count;
    wire selected_ready=backend_ready[q_side];
    wire selected_valid=backend_valid[q_side];
    wire [1:0] selected_kind=backend_kind[q_side*2+:2];
    wire [2:0] selected_status=backend_status[q_side*3+:3];
    wire selected_found=backend_found[q_side];
    wire [PRICE_W-1:0] selected_key=backend_key[q_side*PRICE_W+:PRICE_W];
    wire [QTY_W-1:0] selected_value=backend_value[q_side*QTY_W+:QTY_W];
    wire [CW-1:0] selected_count=backend_count[q_side*CW+:CW];
    wire [PRICE_W-1:0] decoded_price=q_side?selected_key:~selected_key;
    wire [QTY_W:0] added_quantity={1'b0,selected_value}+{1'b0,quantity};
    generate if(LEVELS<1||LEVELS>32||PRICE_W<1||PRICE_W>32||QTY_W<1||QTY_W>32||TAG_W<1||TAG_W>32) begin: invalid
        price_level_order_book_invalid_parameters__see_README invalid_parameters();
    end endgenerate
    genvar side;
    generate for(side=0;side<2;side=side+1) begin: books
        ram_ordered_dictionary #(.CAPACITY(LEVELS),.K_W(PRICE_W),.V_W(QTY_W)) levels (
            .clk(clk),.rst_n(rst_n),
            .s_valid(rst_n&&state==SEND&&q_side==side),.s_ready(backend_ready[side]),
            .s_op(q_op),.s_key(q_key),.s_value(q_value),.s_hi({PRICE_W{1'b1}}),
            .m_valid(backend_valid[side]),.m_ready(state==WAIT_REPLY&&q_side==side),
            .m_kind(backend_kind[side*2+:2]),.m_status(backend_status[side*3+:3]),
            .m_found(backend_found[side]),.m_key(backend_key[side*PRICE_W+:PRICE_W]),
            .m_value(backend_value[side*QTY_W+:QTY_W]),.m_count(backend_count[side*CW+:CW]));
    end endgenerate
    assign c_ready=rst_n&&state==IDLE&&(&backend_ready);
    assign r_valid=rst_n&&state==RESPONSE;
    assign r_bid_levels={{(32-CW){1'b0}},bid_count};
    assign r_ask_levels={{(32-CW){1'b0}},ask_count};
    task finish(input [2:0] status,input found,input [PRICE_W-1:0] at_price,
                input [QTY_W-1:0] after_quantity,before_quantity);
        begin
            r_status<=status;r_found<=found;r_price<=at_price;
            r_quantity<=after_quantity;r_previous<=before_quantity;state<=RESPONSE;
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;phase<=LOOKUP;q_op<=0;q_side<=0;q_key<=0;q_value<=0;
            price<=0;quantity<=0;new_quantity<=0;previous<=0;existed<=0;
            rank<=0;depth_seen<=0;depth_found<=0;depth_price<=0;depth_quantity<=0;
            bid_count<=0;ask_count<=0;
            r_op<=0;r_side<=0;r_status<=0;r_found<=0;r_price<=0;r_quantity<=0;r_previous<=0;r_tag<=0;
        end else case(state)
            IDLE: if(c_valid&&c_ready) begin
                r_op<=c_op;r_side<=c_side;r_tag<=c_tag;
                price<=c_price;quantity<=c_quantity;rank<=c_rank;
                q_side<=c_side;q_key<=c_side?c_price:~c_price;q_value<=0;
                if(c_op>7) finish(BAD_OP,0,0,0,0);
                else if(c_op<=2 && c_quantity==0) finish(BAD_QUANTITY,0,0,0,0);
                else if(c_op==5 && c_rank>=LEVELS) finish(BAD_RANK,0,0,0,0);
                else begin
                    state<=SEND;
                    if(c_op<=3) begin q_op<=0;phase<=LOOKUP;end
                    else if(c_op==4) begin q_op<=3;q_key<=0;phase<=BEST;end
                    else if(c_op==5) begin
                        q_op<=4;q_key<=0;phase<=DEPTH;depth_seen<=0;depth_found<=0;
                    end else begin q_op<=5;phase<=CLEAR;if(c_op==7) q_side<=0;end
                end
            end
            SEND: if(selected_ready) state<=WAIT_REPLY;
            WAIT_REPLY: if(selected_valid) begin
                if(q_side) ask_count<=selected_count;else bid_count<=selected_count;
                case(phase)
                    LOOKUP: begin
                        existed<=selected_found;previous<=selected_found?selected_value:{QTY_W{1'b0}};
                        if(r_op==0) begin
                            q_op<=1;q_value<=quantity;new_quantity<=quantity;phase<=WRITE;state<=SEND;
                        end else if(r_op==1) begin
                            if(selected_found&&added_quantity[QTY_W]) finish(OVERFLOW,0,0,0,0);
                            else begin
                                q_op<=1;q_value<=selected_found?added_quantity[QTY_W-1:0]:quantity;
                                new_quantity<=selected_found?added_quantity[QTY_W-1:0]:quantity;
                                phase<=WRITE;state<=SEND;
                            end
                        end else if(!selected_found) finish(NOT_FOUND,0,0,0,0);
                        else if(r_op==2 && selected_value<quantity) finish(UNDERFLOW,0,0,0,0);
                        else begin
                            q_op<=(r_op==3 || selected_value==quantity)?2:1;
                            q_value<=(r_op==3)?{QTY_W{1'b0}}:selected_value-quantity;
                            new_quantity<=(r_op==3)?{QTY_W{1'b0}}:selected_value-quantity;
                            phase<=WRITE;state<=SEND;
                        end
                    end
                    WRITE: begin
                        if(selected_status==0) finish(OK,existed,price,new_quantity,previous);
                        else if(selected_status==2) finish(FULL,0,0,0,0);
                        else finish(NOT_FOUND,0,0,0,0);
                    end
                    BEST: begin
                        if(selected_found) finish(OK,1,decoded_price,selected_value,0);
                        else finish(NOT_FOUND,0,0,0,0);
                    end
                    DEPTH: begin
                        if(selected_kind==1) begin
                            if(depth_seen==rank) begin
                                depth_found<=1;depth_price<=decoded_price;depth_quantity<=selected_value;
                            end
                            depth_seen<=depth_seen+1'b1;
                        end else if(depth_found) finish(OK,1,depth_price,depth_quantity,0);
                        else finish(NOT_FOUND,0,0,0,0);
                    end
                    CLEAR: begin
                        if(r_op==7&&!q_side) begin q_side<=1;state<=SEND;end
                        else finish(OK,0,0,0,0);
                    end
                    default: finish(BAD_OP,0,0,0,0);
                endcase
            end
            RESPONSE: if(r_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
