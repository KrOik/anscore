// SPDX-License-Identifier: Apache-2.0
// Persistent absolute BBOs by source, with explicit epochs and exact tie sizes.
`default_nettype none
module multi_venue_quote_state #(
    parameter integer SYMBOLS=16,VENUES=4,TAG_W=8
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,input wire [3:0] c_op,
    input wire [31:0] c_symbol,c_venue,input wire [63:0] c_epoch,c_sequence,
    input wire c_bid_valid,c_ask_valid,input wire [31:0] c_bid_price,c_ask_price,
    input wire [37:0] c_bid_quantity,c_ask_quantity,input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,output reg [3:0] r_op,r_status,
    output reg [31:0] r_symbol,r_venue,output reg [63:0] r_epoch,r_sequence,
    output reg r_has_previous,output reg [63:0] r_previous_sequence,
    output reg r_quote_valid,r_bid_valid,r_ask_valid,
    output reg [31:0] r_bid_price,r_ask_price,
    output reg [40:0] r_bid_quantity,r_ask_quantity,
    output reg [7:0] r_bid_sources,r_ask_sources,
    output wire r_locked,r_crossed,output reg [TAG_W-1:0] r_tag,output wire busy
);
    localparam integer S=(SYMBOLS>=1&&SYMBOLS<=32)?SYMBOLS:1;
    localparam integer V=(VENUES>=1&&VENUES<=8)?VENUES:1;
    localparam integer ROWS=S*V,AW=ROWS>1?$clog2(ROWS):1,SW=S>1?$clog2(S):1,VW=V>1?$clog2(V):1;
    localparam [3:0] CONFIG_VENUE=0,DISABLE_VENUE=1,PROBE=2,UPDATE=3,QUERY=4,CLEAR_ALL=5;
    localparam [3:0] OK=0,BAD_SYMBOL=1,BAD_VENUE=2,NOT_CONFIGURED=3,DISABLED=4,
        BAD_EPOCH=5,STALE=6,BAD_QUOTE=7,BACKEND_FAULT=8,BAD_OP=9;
    localparam [2:0] IDLE=0,READ=1,READ_WAIT=2,FINISH=3,WRITE=4,WRITE_WAIT=5,HOLD=6;
    generate if(SYMBOLS<1||SYMBOLS>32||VENUES<1||VENUES>8||TAG_W<1||TAG_W>32)begin:invalid
        multi_venue_quote_state_invalid_parameters__see_README reject();
    end endgenerate
    reg [2:0] state;
    reg [ROWS-1:0] live;
    reg [V-1:0] configured,enabled;
    reg [63:0] venue_epoch[0:V-1];
    reg [VW-1:0] scan_index,target_venue;
    reg [AW-1:0] base_address,target_address;
    reg [271:0] candidate;
    wire [AW-1:0] read_address=r_op==PROBE?target_address:base_address+scan_index;
    wire mem_ready,mem_valid,mem_error;
    wire [271:0] mem_data;
    wire [63:0] row_epoch=mem_data[269:206],row_sequence=mem_data[205:142];
    wire row_bid=mem_data[141],row_ask=mem_data[140];
    wire [31:0] row_bp=mem_data[139:108],row_ap=mem_data[107:76];
    wire [37:0] row_bq=mem_data[75:38],row_aq=mem_data[37:0];
    wire row_present=live[read_address];
    wire row_current=row_present&&row_epoch==venue_epoch[scan_index];
    wire bad_row=mem_data[271:270]!=0 || (row_bid?row_bq==0:(row_bp!=0||row_bq!=0)) ||
        (row_ask?row_aq==0:(row_ap!=0||row_aq!=0));
    wire [271:0] selected=(r_op==UPDATE&&scan_index==target_venue)?candidate:mem_data;
    wire selected_eligible=(r_op==UPDATE&&scan_index==target_venue)||
        (row_current&&configured[scan_index]&&enabled[scan_index]);
    cip_sync_sp_ram #(.DATA_WIDTH(272),.ADDR_WIDTH(AW),.DEPTH(ROWS)) storage(
        .clk(clk),.rst_n(!rst),.clk_en(1'b1),.req_valid(!rst&&(state==READ||state==WRITE)),
        .req_ready(mem_ready),.req_write(state==WRITE),.req_addr(state==WRITE?target_address:read_address),
        .req_wdata(candidate),.req_wstrb(34'h3ffffffff),.rsp_valid(mem_valid),
        .rsp_ready(state==READ_WAIT||state==WRITE_WAIT),.rsp_rdata(mem_data),.rsp_error(mem_error));
    assign c_ready=!rst&&state==IDLE;
    assign r_valid=!rst&&state==HOLD;
    assign busy=!rst&&state!=IDLE;
    assign r_locked=r_quote_valid&&r_bid_valid&&r_ask_valid&&r_bid_price==r_ask_price;
    assign r_crossed=r_quote_valid&&r_bid_valid&&r_ask_valid&&r_bid_price>r_ask_price;
    task clear_quote;
        begin r_quote_valid<=0;r_bid_valid<=0;r_ask_valid<=0;r_bid_price<=0;r_ask_price<=0;
            r_bid_quantity<=0;r_ask_quantity<=0;r_bid_sources<=0;r_ask_sources<=0;end
    endtask
    task fail(input [3:0] status);
        begin r_status<=status;clear_quote();state<=HOLD;
            if(status==BACKEND_FAULT)begin r_has_previous<=0;r_previous_sequence<=0;end
        end
    endtask
    task include_quote(input [271:0] value,input [VW-1:0] source_index);
        begin
            if(value[141])begin
                if(!r_bid_valid||value[139:108]>r_bid_price)begin
                    r_bid_valid<=1;r_bid_price<=value[139:108];r_bid_quantity<={3'd0,value[75:38]};
                    r_bid_sources<=8'b1<<source_index;
                end else if(value[139:108]==r_bid_price)begin
                    r_bid_quantity<=r_bid_quantity+{3'd0,value[75:38]};r_bid_sources<=r_bid_sources|(8'b1<<source_index);
                end
            end
            if(value[140])begin
                if(!r_ask_valid||value[107:76]<r_ask_price)begin
                    r_ask_valid<=1;r_ask_price<=value[107:76];r_ask_quantity<={3'd0,value[37:0]};
                    r_ask_sources<=8'b1<<source_index;
                end else if(value[107:76]==r_ask_price)begin
                    r_ask_quantity<=r_ask_quantity+{3'd0,value[37:0]};r_ask_sources<=r_ask_sources|(8'b1<<source_index);
                end
            end
        end
    endtask
    integer i;
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;live<=0;configured<=0;enabled<=0;scan_index<=0;target_venue<=0;
            base_address<=0;target_address<=0;candidate<=0;
            for(i=0;i<V;i=i+1)venue_epoch[i]<=0;
            r_op<=0;r_status<=0;r_symbol<=0;r_venue<=0;r_epoch<=0;r_sequence<=0;
            r_has_previous<=0;r_previous_sequence<=0;r_tag<=0;clear_quote();
        end else case(state)
            IDLE:if(c_valid)begin
                r_op<=c_op;r_status<=OK;r_symbol<=c_symbol;r_venue<=c_venue;
                r_epoch<=c_epoch;r_sequence<=c_sequence;r_tag<=c_tag;
                r_has_previous<=0;r_previous_sequence<=0;clear_quote();
                target_venue<=c_venue[VW-1:0];
                // Multiplication is by the elaboration constant V<=8 only.
                base_address<=c_symbol[SW-1:0]*V;
                target_address<=c_symbol[SW-1:0]*V+c_venue[VW-1:0];
                candidate<={2'd0,c_epoch,c_sequence,c_bid_valid,c_ask_valid,
                    c_bid_valid?c_bid_price:32'd0,c_ask_valid?c_ask_price:32'd0,
                    c_bid_valid?c_bid_quantity:38'd0,c_ask_valid?c_ask_quantity:38'd0};
                scan_index<=c_op==PROBE?c_venue[VW-1:0]:{VW{1'b0}};
                if(c_op>CLEAR_ALL)fail(BAD_OP);
                else if(c_op==CLEAR_ALL)begin live<=0;configured<=0;enabled<=0;state<=HOLD;end
                else if(c_op==CONFIG_VENUE||c_op==DISABLE_VENUE)begin
                    if(c_venue>=V)fail(BAD_VENUE);
                    else if(c_op==CONFIG_VENUE)begin
                        if(configured[c_venue]&&c_epoch<=venue_epoch[c_venue])fail(BAD_EPOCH);
                        else begin configured[c_venue]<=1;enabled[c_venue]<=1;venue_epoch[c_venue]<=c_epoch;state<=HOLD;end
                    end else if(!configured[c_venue])fail(NOT_CONFIGURED);
                    else begin enabled[c_venue]<=0;state<=HOLD;end
                end else if(c_symbol>=S)fail(BAD_SYMBOL);
                else if(c_op==QUERY)state<=READ;
                else if(c_venue>=V)fail(BAD_VENUE);
                else if(!configured[c_venue])fail(NOT_CONFIGURED);
                else if(!enabled[c_venue])fail(DISABLED);
                else if(c_epoch!=venue_epoch[c_venue])fail(BAD_EPOCH);
                else if(c_op==UPDATE&&((c_bid_valid&&c_bid_quantity==0)||(c_ask_valid&&c_ask_quantity==0)))fail(BAD_QUOTE);
                else state<=READ;
            end
            READ:if(mem_ready)state<=READ_WAIT;
            READ_WAIT:if(mem_valid)begin
                if(mem_error||(row_present&&bad_row))fail(BACKEND_FAULT);
                else begin
                    if((r_op==PROBE||r_op==UPDATE)&&scan_index==target_venue&&row_current)begin
                        r_has_previous<=1;r_previous_sequence<=row_sequence;
                    end
                    if((r_op==PROBE||r_op==UPDATE)&&scan_index==target_venue&&row_current&&r_sequence<=row_sequence)fail(STALE);
                    else if(r_op==PROBE)state<=HOLD;
                    else begin
                        if(selected_eligible)include_quote(selected,scan_index);
                        if(scan_index==V-1)state<=FINISH;
                        else begin scan_index<=scan_index+1'b1;state<=READ;end
                    end
                end
            end
            FINISH:if(r_op==QUERY)begin r_quote_valid<=1;state<=HOLD;end else state<=WRITE;
            WRITE:if(mem_ready)state<=WRITE_WAIT;
            WRITE_WAIT:if(mem_valid)begin
                if(mem_error)fail(BACKEND_FAULT);
                else begin live[target_address]<=1;r_quote_valid<=1;state<=HOLD;end
            end
            HOLD:if(r_ready)state<=IDLE;
            default:fail(BACKEND_FAULT);
        endcase
    end
endmodule
`default_nettype wire
