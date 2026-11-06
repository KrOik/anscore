// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE bounded limit-only auction indication. One synchronous row port.
`default_nettype none
module call_auction_clear #(
    parameter integer MAX_ROWS=32, PRICE_W=32, QTY_W=32, TAG_W=8,
    parameter integer SUM_W=QTY_W+$clog2(MAX_ROWS+1)
) (
    input wire clk, input wire rst_n,
    input wire a_valid, output wire a_ready,
    input wire [31:0] a_rows,
    input wire [PRICE_W-1:0] a_reference,
    input wire [TAG_W-1:0] a_tag,
    input wire s_valid, output wire s_ready,
    input wire s_side,
    input wire [PRICE_W-1:0] s_price,
    input wire [QTY_W-1:0] s_quantity,
    output wire m_valid, input wire m_ready,
    output reg [1:0] m_status,
    output reg [31:0] m_rows,
    output reg [PRICE_W-1:0] m_price,
    output reg [SUM_W-1:0] m_matched, m_buy, m_sell,
    output reg signed [SUM_W:0] m_imbalance,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer IW=(MAX_ROWS<2)?1:$clog2(MAX_ROWS);
    localparam integer CW=$clog2(MAX_ROWS+1);
    localparam integer ROW_W=1+PRICE_W+QTY_W;
    localparam [3:0] IDLE=0,LOAD=1,CAND_READ=2,CAND_HAVE=3,
        SCAN_READ=4,SCAN_ACC=5,EVALUATE=6,FINISH=7,RESPONSE=8;
    localparam [1:0] CLEAR=0,NO_CROSS=1,BAD_COUNT=2,BAD_QUANTITY=3;
    reg [3:0] state;
    reg [ROW_W-1:0] rows [0:MAX_ROWS-1];
    reg [ROW_W-1:0] row_q;
    reg [CW-1:0] count;
    reg [IW-1:0] load_index,candidate_index,scan_index;
    reg bad_quantity,best_valid;
    reg [PRICE_W-1:0] reference_price,candidate_price,best_price,best_distance;
    reg [SUM_W-1:0] buy_sum,sell_sum,strict_buy,strict_sell;
    reg [SUM_W-1:0] best_volume,best_abs,best_buy,best_sell;
    wire row_side=row_q[ROW_W-1];
    wire [PRICE_W-1:0] row_price=row_q[QTY_W+:PRICE_W];
    wire [SUM_W-1:0] row_quantity={{(SUM_W-QTY_W){1'b0}},row_q[QTY_W-1:0]};
    wire [SUM_W-1:0] next_buy=buy_sum+((!row_side&&row_price>=candidate_price)?row_quantity:{SUM_W{1'b0}});
    wire [SUM_W-1:0] next_sell=sell_sum+((row_side&&row_price<=candidate_price)?row_quantity:{SUM_W{1'b0}});
    wire [SUM_W-1:0] next_strict_buy=strict_buy+((!row_side&&row_price>candidate_price)?row_quantity:{SUM_W{1'b0}});
    wire [SUM_W-1:0] next_strict_sell=strict_sell+((row_side&&row_price<candidate_price)?row_quantity:{SUM_W{1'b0}});
    wire [SUM_W-1:0] volume=(buy_sum<sell_sum)?buy_sum:sell_sum;
    wire [SUM_W-1:0] absolute_imbalance=(buy_sum>=sell_sum)?buy_sum-sell_sum:sell_sum-buy_sum;
    wire [PRICE_W-1:0] distance=(candidate_price>=reference_price)?candidate_price-reference_price:reference_price-candidate_price;
    wire eligible=(strict_buy<=volume)&&(strict_sell<=volume);
    wire better=!best_valid||(volume>best_volume)||
        ((volume==best_volume)&&((absolute_imbalance<best_abs)||
        ((absolute_imbalance==best_abs)&&((distance<best_distance)||
        ((distance==best_distance)&&(candidate_price<best_price))))));
    generate if(MAX_ROWS<1||MAX_ROWS>64||PRICE_W<1||PRICE_W>32||
        QTY_W<1||QTY_W>32||TAG_W<1||TAG_W>32||SUM_W!=QTY_W+$clog2(MAX_ROWS+1)) begin: invalid
        call_auction_clear_invalid_parameters__see_README invalid_parameters();
    end endgenerate
    assign a_ready=rst_n&&(state==IDLE);
    assign s_ready=rst_n&&(state==LOAD);
    assign m_valid=rst_n&&(state==RESPONSE);
    // No contents reset: every row in the valid range is overwritten before use.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;row_q<=0;count<=0;load_index<=0;candidate_index<=0;scan_index<=0;
            bad_quantity<=0;best_valid<=0;reference_price<=0;candidate_price<=0;
            best_price<=0;best_distance<=0;buy_sum<=0;sell_sum<=0;strict_buy<=0;strict_sell<=0;
            best_volume<=0;best_abs<=0;best_buy<=0;best_sell<=0;
            m_status<=0;m_rows<=0;m_price<=0;m_matched<=0;m_buy<=0;m_sell<=0;m_imbalance<=0;m_tag<=0;
        end else case(state)
            IDLE: if(a_valid&&a_ready) begin
                m_rows<=a_rows;m_tag<=a_tag;reference_price<=a_reference;
                m_price<=0;m_matched<=0;m_buy<=0;m_sell<=0;m_imbalance<=0;
                best_valid<=0;bad_quantity<=0;load_index<=0;
                if(a_rows>MAX_ROWS) begin m_status<=BAD_COUNT;state<=RESPONSE;end
                else if(a_rows==0) begin m_status<=NO_CROSS;state<=RESPONSE;end
                else begin count<=a_rows[CW-1:0];state<=LOAD;end
            end
            LOAD: if(s_valid&&s_ready) begin
                rows[load_index]<={s_side,s_price,s_quantity};
                bad_quantity<=bad_quantity||(s_quantity==0);
                if({1'b0,load_index}+1'b1==count) begin
                    if(bad_quantity||(s_quantity==0)) begin m_status<=BAD_QUANTITY;state<=RESPONSE;end
                    else begin candidate_index<=0;state<=CAND_READ;end
                end else load_index<=load_index+1'b1;
            end
            CAND_READ: begin row_q<=rows[candidate_index];state<=CAND_HAVE;end
            CAND_HAVE: begin
                candidate_price<=row_price;scan_index<=0;
                buy_sum<=0;sell_sum<=0;strict_buy<=0;strict_sell<=0;state<=SCAN_READ;
            end
            SCAN_READ: begin row_q<=rows[scan_index];state<=SCAN_ACC;end
            SCAN_ACC: begin
                buy_sum<=next_buy;sell_sum<=next_sell;
                strict_buy<=next_strict_buy;strict_sell<=next_strict_sell;
                if({1'b0,scan_index}+1'b1==count) state<=EVALUATE;
                else begin scan_index<=scan_index+1'b1;state<=SCAN_READ;end
            end
            EVALUATE: begin
                if(eligible&&(volume!=0)&&better) begin
                    best_valid<=1;best_price<=candidate_price;best_distance<=distance;
                    best_volume<=volume;best_abs<=absolute_imbalance;best_buy<=buy_sum;best_sell<=sell_sum;
                end
                if({1'b0,candidate_index}+1'b1==count) state<=FINISH;
                else begin candidate_index<=candidate_index+1'b1;state<=CAND_READ;end
            end
            FINISH: begin
                m_status<=best_valid?CLEAR:NO_CROSS;
                if(best_valid) begin
                    m_price<=best_price;m_matched<=best_volume;m_buy<=best_buy;m_sell<=best_sell;
                    m_imbalance<=$signed({1'b0,best_buy})-$signed({1'b0,best_sell});
                end
                state<=RESPONSE;
            end
            RESPONSE: if(m_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
