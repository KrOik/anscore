// SPDX-License-Identifier: Apache-2.0
// Masked vector memory service. Bank conflicts replay in ascending lane order.
module vector_banked_scratchpad #(
    parameter integer LANES=4,
    parameter integer BANKS=4,
    parameter integer WORDS=64,
    parameter integer DATA_W=32,
    parameter integer TAG_W=8,
    localparam integer ROW_W=(WORDS<2)?1:$clog2(WORDS),
    localparam integer LANE_W=(LANES<2)?1:$clog2(LANES),
    localparam integer COUNT_W=(LANES<2)?1:$clog2(LANES+1)
)(
    input wire clk, rst_n,
    input wire s_valid,
    output wire s_ready,
    input wire [LANES-1:0] s_mask, s_write,
    input wire [LANES*32-1:0] s_address,
    input wire [LANES*DATA_W-1:0] s_data,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output reg [1:0] m_status,
    output reg [LANES-1:0] m_mask, m_error_mask,
    output reg [LANES*DATA_W-1:0] m_data,
    output reg [TAG_W-1:0] m_tag,
    output reg [COUNT_W-1:0] m_accesses, m_rounds
);
    generate
    if(LANES<1 || LANES>8 ||
       !(BANKS==1 || BANKS==2 || BANKS==4 || BANKS==8) ||
       WORDS<1 || WORDS>256 || DATA_W<8 || DATA_W>64 || DATA_W%8!=0 ||
       TAG_W<1 || TAG_W>32) begin: invalid_parameters
        vector_banked_scratchpad_invalid_parameters__see_README reject();
    end else begin: implementation
    localparam [2:0] IDLE=0, PREFLIGHT=1, ISSUE=2, COLLECT=3, RESPONSE=4;
    localparam integer TOTAL_WORDS=BANKS*WORDS;
    // The full public word address is compared before row narrowing.
    localparam [32:0] LIMIT_WORDS=TOTAL_WORDS;
    reg [2:0] state;
    reg [LANES-1:0] pending, write_q;
    reg [LANES*32-1:0] address_q;
    reg [LANES*DATA_W-1:0] data_q;
    reg [BANKS-1:0] active_banks;
    reg [BANKS*LANE_W-1:0] owner_q;
    reg [BANKS-1:0] bank_req_valid, bank_req_write;
    wire [BANKS-1:0] bank_req_ready, bank_rsp_valid, bank_rsp_error;
    reg [BANKS*ROW_W-1:0] bank_req_address;
    reg [BANKS*DATA_W-1:0] bank_req_data;
    wire [BANKS*DATA_W-1:0] bank_rsp_data;
    wire [BANKS-1:0] bank_rsp_ready;
    reg [BANKS*LANE_W-1:0] chosen_lanes;
    reg [LANES-1:0] chosen_mask, invalid_mask;
    reg [BANKS-1:0] found;
    reg [COUNT_W-1:0] round_accesses;
    integer b, l, check_lane;
    integer a;

    assign s_ready=rst_n && state==IDLE;
    assign m_valid=rst_n && state==RESPONSE;
    assign bank_rsp_ready={BANKS{rst_n && state==COLLECT}} & active_banks;

    always @* begin
        invalid_mask={LANES{1'b0}};
        for(check_lane=0;check_lane<LANES;check_lane=check_lane+1)
            if(m_mask[check_lane] && {1'b0,address_q[check_lane*32+:32]}>=LIMIT_WORDS)
                invalid_mask[check_lane]=1'b1;
    end

    // One winner per bank. Repeating rounds preserves the lane order within
    // each bank, including mixed reads/writes to the same word. There is no
    // duplicate-read suppression: an intervening write must be observed.
    always @* begin
        bank_req_valid={BANKS{1'b0}};
        bank_req_write={BANKS{1'b0}};
        bank_req_address={BANKS*ROW_W{1'b0}};
        bank_req_data={BANKS*DATA_W{1'b0}};
        chosen_lanes={BANKS*LANE_W{1'b0}};
        chosen_mask={LANES{1'b0}};
        found={BANKS{1'b0}};
        for(b=0;b<BANKS;b=b+1) begin
            for(l=0;l<LANES;l=l+1) begin
                if(!found[b] && pending[l] &&
                   ((address_q[l*32+:32] & (BANKS-1))==b)) begin
                    found[b]=1'b1;
                    chosen_lanes[b*LANE_W+:LANE_W]=l;
                    chosen_mask[l]=1'b1;
                    bank_req_address[b*ROW_W+:ROW_W]=address_q[l*32+:32] >>
                        ((BANKS<2)?0:$clog2(BANKS));
                    bank_req_write[b]=write_q[l];
                    bank_req_data[b*DATA_W+:DATA_W]=data_q[l*DATA_W+:DATA_W];
                end
            end
        end
        // All internal response slots are empty at ISSUE. Waiting for all
        // ready signals makes acceptance of a round simultaneous, never partial.
        if(rst_n && state==ISSUE && ((bank_req_ready & found)==found))
            bank_req_valid=found;
    end

    genvar g;
        for(g=0;g<BANKS;g=g+1) begin: banks
            // Exact unchanged local dependency; CE=1 converts its shared-CE
            // transaction convention into ordinary ready/valid on every edge.
            // It returns the OLD word on writes; those response bits are ignored.
            cip_sync_sp_ram #(.DATA_WIDTH(DATA_W),.ADDR_WIDTH(ROW_W),.DEPTH(WORDS)) ram(
                .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
                .req_valid(bank_req_valid[g]),.req_ready(bank_req_ready[g]),
                .req_write(bank_req_write[g]),
                .req_addr(bank_req_address[g*ROW_W+:ROW_W]),
                .req_wdata(bank_req_data[g*DATA_W+:DATA_W]),
                .req_wstrb({DATA_W/8{1'b1}}),
                .rsp_valid(bank_rsp_valid[g]),.rsp_ready(bank_rsp_ready[g]),
                .rsp_rdata(bank_rsp_data[g*DATA_W+:DATA_W]),
                .rsp_error(bank_rsp_error[g]));
        end

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; pending<=0; write_q<=0; address_q<=0; data_q<=0;
            active_banks<=0; owner_q<=0;
            m_status<=0; m_mask<=0; m_error_mask<=0; m_data<=0;
            m_tag<=0; m_accesses<=0; m_rounds<=0;
        end else case(state)
            IDLE: if(s_valid && s_ready) begin
                m_mask<=s_mask; write_q<=s_write;
                address_q<=s_address; data_q<=s_data; m_tag<=s_tag;
                m_status<=0; m_error_mask<=0; m_data<=0;
                m_accesses<=0; m_rounds<=0; pending<=0;
                active_banks<=0; state<=PREFLIGHT;
            end
            PREFLIGHT: begin
                // Whole-vector address rejection: even an earlier good store
                // cannot escape before a later lane is found out of range.
                if(invalid_mask!=0) begin
                    m_status<=1; m_error_mask<=invalid_mask; state<=RESPONSE;
                end else if(m_mask==0) state<=RESPONSE;
                else begin pending<=m_mask; state<=ISSUE; end
            end
            ISSUE: if(found!=0 && ((bank_req_valid & bank_req_ready)==found)) begin
                active_banks<=found; owner_q<=chosen_lanes;
                pending<=pending & ~chosen_mask;
                // chosen_mask is disjoint across rounds of one vector.
                m_accesses<=m_accesses+round_accesses;
                m_rounds<=m_rounds+1'b1;
                state<=COLLECT;
            end
            COLLECT: begin
                active_banks<=active_banks & ~bank_rsp_valid;
                for(k=0;k<BANKS;k=k+1) begin
                    if(active_banks[k] && bank_rsp_valid[k]) begin
                        if(bank_rsp_error[k]) begin
                            m_status<=2; m_error_mask[owner_q[k*LANE_W+:LANE_W]]<=1'b1;
                            m_data[owner_q[k*LANE_W+:LANE_W]*DATA_W+:DATA_W]<=0;
                        end else if(!write_q[owner_q[k*LANE_W+:LANE_W]])
                            m_data[owner_q[k*LANE_W+:LANE_W]*DATA_W+:DATA_W]<=bank_rsp_data[k*DATA_W+:DATA_W];
                        // Store results remain canonical zero even if the
                        // RAM's read-first old data contains unknown bits.
                    end
                end
                if((bank_rsp_valid & active_banks)==active_banks) begin
                    active_banks<=0;
                    state<=pending==0?RESPONSE:ISSUE;
                end
            end
            RESPONSE: if(m_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end

    // A small explicit popcount avoids nonblocking accumulation in a loop.
    always @* begin
        round_accesses=0;
        for(a=0;a<LANES;a=a+1) if(chosen_mask[a]) round_accesses=round_accesses+1'b1;
    end
    end
    endgenerate
endmodule
