// SPDX-License-Identifier: Apache-2.0
`default_nettype none
// Actual OUCH decoder -> venue-confirmed reservations. See scope in README.
module ouch42_order_risk #(
    parameter integer CONTEXTS=4,ORDERS=8,TAG_W=8
)(
    input wire clk,rst_n,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
    input wire [TAG_W-1:0] s_tag,
    input wire c_valid,output wire c_ready,input wire [3:0] c_op,
    input wire [31:0] c_context,input wire [111:0] c_token,input wire c_buy,
    input wire [31:0] c_quantity,input wire signed [63:0] c_position,c_min_position,c_max_position,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,output reg r_venue,
    output reg [7:0] r_type,output reg [2:0] r_decode_status,output reg [1:0] r_stage,
    output reg [4:0] r_status,output reg [3:0] r_op,output reg [111:0] r_token,
    output reg [31:0] r_context,r_remaining,r_live,output reg r_buy,
    output reg [1:0] r_phase,output reg signed [63:0] r_position,
    output reg [37:0] r_buy_open,r_sell_open,output reg [TAG_W-1:0] r_tag,
    output wire faulted
);
    localparam [2:0] IDLE=0,SEND=1,WAIT_REPLY=2,ISOLATE_SEND=3,ISOLATE_WAIT=4,RESPONSE=5;
    reg [2:0] state;
    wire dv,dr;wire [2:0] ds;wire [7:0] dt;wire [15:0] dl;
    wire [TAG_W-1:0] dtag;wire [719:0] event_data;
    nasdaq_ouch42_server_rx #(.TAG_W(TAG_W)) decoder(
        .clk(clk),.rst(!rst_n),.s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),.s_tag(s_tag),
        .r_valid(dv),.r_ready(dr),.r_status(ds),.r_type(dt),.r_length(dl),.r_tag(dtag),.r_event(event_data));
    reg [3:0] command;
    reg [31:0] context_id,quantity;
    reg [111:0] token;
    reg buy;
    reg signed [63:0] position_in,min_in,max_in;
    wire cr,rv;wire [3:0] ro;wire [4:0] rs;
    wire [111:0] rt;wire [31:0] rc,rq,rl;wire rb;wire [1:0] rp;
    wire signed [63:0] pos;wire [37:0] bo,so;wire [TAG_W-1:0] tag_out;
    order_risk_reservation #(.CONTEXTS(CONTEXTS),.ORDERS(ORDERS),.TAG_W(TAG_W)) risk(
        .clk(clk),.rst_n(rst_n),.c_valid(state==SEND||state==ISOLATE_SEND),.c_ready(cr),
        .c_op(state==ISOLATE_SEND?4'd11:command),.c_context(context_id),.c_token(token),.c_buy(buy),
        .c_quantity(quantity),.c_position(position_in),.c_min_position(min_in),.c_max_position(max_in),.c_tag(r_tag),
        .r_valid(rv),.r_ready(state==WAIT_REPLY||state==ISOLATE_WAIT),.r_op(ro),.r_status(rs),
        .r_token(rt),.r_context(rc),.r_buy(rb),.r_remaining(rq),.r_phase(rp),
        .r_position(pos),.r_min_position(),.r_max_position(),.r_buy_open(bo),.r_sell_open(so),
        .r_live(rl),.r_tag(tag_out),.busy(),.faulted(faulted));
    assign c_ready=rst_n&&state==IDLE;
    assign dr=rst_n&&state==IDLE&&!c_valid;
    assign r_valid=rst_n&&state==RESPONSE;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;command<=0;context_id<=0;quantity<=0;token<=0;buy<=0;
            position_in<=0;min_in<=0;max_in<=0;
            r_venue<=0;r_type<=0;r_decode_status<=0;r_stage<=0;r_status<=0;r_op<=0;r_token<=0;
            r_context<=0;r_remaining<=0;r_live<=0;r_buy<=0;r_phase<=0;r_position<=0;
            r_buy_open<=0;r_sell_open<=0;r_tag<=0;
        end else case(state)
            IDLE:begin
                if(c_valid||dv)begin
                    r_status<=0;r_stage<=0;r_context<=0;r_remaining<=0;r_live<=0;r_buy<=0;
                    r_phase<=0;r_position<=0;r_buy_open<=0;r_sell_open<=0;
                    if(c_valid)begin
                        r_venue<=0;r_type<=0;r_decode_status<=0;r_tag<=c_tag;r_op<=c_op;r_token<=c_token;
                        command<=c_op;context_id<=c_context;token<=c_token;buy<=c_buy;quantity<=c_quantity;
                        position_in<=c_position;min_in<=c_min_position;max_in<=c_max_position;state<=SEND;
                    end else begin
                        r_venue<=1;r_type<=dt;r_decode_status<=ds;r_tag<=dtag;r_token<=event_data[655:544];
                        token<=event_data[655:544];quantity<=event_data[423:392];buy<=event_data[431:424]==8'h42;
                        context_id<=0;position_in<=0;min_in<=0;max_in<=0;
                        if(ds!=0)begin r_op<=11;r_status<=16;r_stage<=2;state<=ISOLATE_SEND;end
                        else case(dt)
                            8'h41:begin
                                r_op<=2;command<=2;
                                if(event_data[103:96]!=8'h4c)begin r_status<=17;r_stage<=2;state<=ISOLATE_SEND;end
                                else state<=SEND;
                            end
                            8'h45:begin r_op<=7;command<=7;state<=SEND;end
                            8'h43:begin r_op<=5;command<=5;state<=SEND;end
                            8'h4a:begin r_op<=3;command<=3;state<=SEND;end
                            8'h53:begin r_op<=15;state<=RESPONSE;end
                            default:begin r_op<=11;r_status<=17;r_stage<=2;state<=ISOLATE_SEND;end
                        endcase
                    end
                end
            end
            SEND:if(cr)state<=WAIT_REPLY;
            WAIT_REPLY:if(rv)begin
                r_status<=rs;
                if(r_venue&&rs!=0)begin r_stage<=2;state<=ISOLATE_SEND;end
                else begin
                    r_context<=rc;r_remaining<=rq;r_live<=rl;r_buy<=rb;r_phase<=rp;
                    r_position<=pos;r_buy_open<=bo;r_sell_open<=so;state<=RESPONSE;
                end
            end
            ISOLATE_SEND:if(cr)state<=ISOLATE_WAIT;
            ISOLATE_WAIT:if(rv)state<=RESPONSE;
            RESPONSE:if(r_ready)state<=IDLE;
            default:begin r_stage<=2;r_status<=15;state<=ISOLATE_SEND;end
        endcase
    end
endmodule
`default_nettype wire
