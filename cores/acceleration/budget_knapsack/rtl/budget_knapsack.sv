`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Exact 0/1 selection: maximum value, minimum cost, minimum selection bitmap.
module budget_knapsack #(
    parameter integer MAX_ITEMS=16,MAX_CAPACITY=63,COST_W=8,VALUE_W=16,TAG_W=8,
    localparam integer INDEX_W=(MAX_ITEMS>1)?$clog2(MAX_ITEMS):1,
    localparam integer COUNT_W=(MAX_ITEMS>0)?$clog2(MAX_ITEMS+1):1,
    localparam integer BUDGET_W=(MAX_CAPACITY>0)?$clog2(MAX_CAPACITY+1):1,
    localparam integer SUM_W=VALUE_W+((MAX_ITEMS>1)?$clog2(MAX_ITEMS):0)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [COST_W-1:0] s_cost,
    input wire [VALUE_W-1:0] s_value,
    input wire s_keep,s_last,
    input wire [31:0] s_capacity,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire m_keep,m_selected,m_first,m_last,
    output wire [INDEX_W-1:0] m_index,
    output wire [COST_W-1:0] m_cost,
    output wire [VALUE_W-1:0] m_value,
    output wire [COUNT_W-1:0] m_count,
    output reg [SUM_W-1:0] m_total_value,
    output reg [BUDGET_W-1:0] m_total_cost,
    output wire [1:0] m_error,
    output reg [31:0] m_capacity,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer RECORD_W=MAX_ITEMS+BUDGET_W+SUM_W;
    localparam integer ADD_W=((COST_W>BUDGET_W)?COST_W:BUDGET_W)+1;
    localparam [3:0] COLLECT=0,INITIALIZE=1,ITEM_READ=2,ITEM_SETUP=3,
        CURRENT_READ=4,BASE_READ=5,UPDATE=6,FINAL_READ=7,FINALIZE=8,
        OUTPUT_READ=9,OUTPUT_HOLD=10,STATUS_HOLD=11;
    reg [3:0] state;
    reg [COST_W+VALUE_W-1:0] items[0:MAX_ITEMS-1];
    // Every budget record stores {selection bitmap, used cost, total value}.
    reg [RECORD_W-1:0] dp[0:MAX_CAPACITY];
    reg [RECORD_W-1:0] current_q,base_q,final_q;
    reg [COST_W+VALUE_W-1:0] item_q,output_q;
    reg [MAX_ITEMS-1:0] best_mask;
    reg [INDEX_W-1:0] item_index,out_index;
    reg [COUNT_W-1:0] count;
    reg [BUDGET_W-1:0] init_index,budget;
    reg [1:0] errors;
    reg started;
    wire [BUDGET_W-1:0] active_capacity=m_capacity[BUDGET_W-1:0];
    wire [COST_W-1:0] item_cost=item_q[VALUE_W+:COST_W];
    wire [VALUE_W-1:0] item_value=item_q[VALUE_W-1:0];
    wire [BUDGET_W-1:0] base_address=budget-item_cost;
    wire [SUM_W:0] candidate_value={1'b0,base_q[SUM_W-1:0]}+
        {{(SUM_W+1-VALUE_W){1'b0}},item_value};
    wire [ADD_W-1:0] candidate_cost=
        {{(ADD_W-BUDGET_W){1'b0}},base_q[SUM_W+:BUDGET_W]}+
        {{(ADD_W-COST_W){1'b0}},item_cost};
    wire [MAX_ITEMS-1:0] candidate_mask=base_q[SUM_W+BUDGET_W+:MAX_ITEMS] |
        ({{(MAX_ITEMS-1){1'b0}},1'b1}<<item_index);
    wire improves=(candidate_value>{1'b0,current_q[SUM_W-1:0]}) ||
        (candidate_value=={1'b0,current_q[SUM_W-1:0]} &&
         candidate_cost<{{(ADD_W-BUDGET_W){1'b0}},current_q[SUM_W+:BUDGET_W]});
    wire [1:0] incoming_errors=errors |
        {(!started && s_capacity>MAX_CAPACITY),(s_keep && count==MAX_ITEMS)};
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && (state==OUTPUT_HOLD || state==STATUS_HOLD);
    assign m_keep=state==OUTPUT_HOLD;
    assign m_selected=m_keep && best_mask[out_index];
    assign m_index=m_keep?out_index:{INDEX_W{1'b0}};
    assign m_cost=m_keep?output_q[VALUE_W+:COST_W]:{COST_W{1'b0}};
    assign m_value=m_keep?output_q[VALUE_W-1:0]:{VALUE_W{1'b0}};
    assign m_count=m_keep?count:{COUNT_W{1'b0}};
    assign m_first=!m_keep || out_index==0;
    assign m_last=!m_keep || out_index==count-1'b1;
    assign m_error=errors;
    generate if(MAX_ITEMS<1 || MAX_ITEMS>64 || MAX_CAPACITY<0 || MAX_CAPACITY>255 ||
                COST_W<1 || COST_W>16 || VALUE_W<1 || VALUE_W>24 || TAG_W<1 || TAG_W>32)
        begin : g_invalid
            budget_knapsack_invalid_parameters__see_README invalid_configuration();
        end
    endgenerate
    task advance_item;
        begin
            if(item_index==count-1'b1) state<=FINAL_READ;
            else begin item_index<=item_index+1'b1;state<=ITEM_READ;end
        end
    endtask
    task retire_frame;
        begin
            count<=0;started<=0;errors<=0;m_capacity<=0;m_tag<=0;
            m_total_value<=0;m_total_cost<=0;best_mask<=0;state<=COLLECT;
        end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=COLLECT;count<=0;started<=0;errors<=0;
            m_capacity<=0;m_tag<=0;m_total_value<=0;m_total_cost<=0;
            current_q<=0;base_q<=0;final_q<=0;item_q<=0;output_q<=0;best_mask<=0;
            item_index<=0;out_index<=0;init_index<=0;budget<=0;
        end else case(state)
            COLLECT: if(s_valid) begin
                if(!started) begin started<=1;m_capacity<=s_capacity;m_tag<=s_tag;end
                errors<=incoming_errors;
                if(s_keep && count<MAX_ITEMS) begin items[count]<={s_cost,s_value};count<=count+1'b1;end
                if(s_last) begin
                    out_index<=0;
                    if(incoming_errors!=0 || (!s_keep && count==0)) begin
                        m_total_value<=0;m_total_cost<=0;state<=STATUS_HOLD;
                    end else begin init_index<=0;state<=INITIALIZE;end
                end
            end
            INITIALIZE: begin
                dp[init_index]<=0;
                if(init_index==active_capacity) begin item_index<=0;state<=ITEM_READ;end
                else init_index<=init_index+1'b1;
            end
            ITEM_READ: begin item_q<=items[item_index];state<=ITEM_SETUP;end
            ITEM_SETUP: if(item_cost>active_capacity) advance_item();
                else begin budget<=active_capacity;state<=CURRENT_READ;end
            CURRENT_READ: begin current_q<=dp[budget];state<=BASE_READ;end
            BASE_READ: begin base_q<=dp[base_address];state<=UPDATE;end
            UPDATE: begin
                if(improves) dp[budget]<={candidate_mask,candidate_cost[BUDGET_W-1:0],candidate_value[SUM_W-1:0]};
                // Descending budgets ensure each item is used once. For cost=0,
                // both reads see the same old record before this single write.
                if(budget==item_cost) advance_item();
                else begin budget<=budget-1'b1;state<=CURRENT_READ;end
            end
            FINAL_READ: begin final_q<=dp[active_capacity];state<=FINALIZE;end
            FINALIZE: begin
                m_total_value<=final_q[SUM_W-1:0];m_total_cost<=final_q[SUM_W+:BUDGET_W];
                best_mask<=final_q[SUM_W+BUDGET_W+:MAX_ITEMS];out_index<=0;state<=OUTPUT_READ;
            end
            OUTPUT_READ: begin output_q<=items[out_index];state<=OUTPUT_HOLD;end
            OUTPUT_HOLD: if(m_ready) begin
                if(out_index==count-1'b1) retire_frame();
                else begin out_index<=out_index+1'b1;state<=OUTPUT_READ;end
            end
            STATUS_HOLD: if(m_ready) retire_frame();
            default: state<=COLLECT;
        endcase
    end
endmodule
