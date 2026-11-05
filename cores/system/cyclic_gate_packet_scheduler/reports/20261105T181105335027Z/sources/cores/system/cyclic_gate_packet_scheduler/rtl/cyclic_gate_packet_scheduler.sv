// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE cyclic gate plan + FIFO packet descriptors + service reservation.
`default_nettype none
module cyclic_gate_packet_scheduler #(
    parameter integer QUEUES=4,DEPTH=4,SLOTS=4,TICK_W=16,DATA_W=32,TAG_W=8
) (
    input wire clk,input wire rst_n,
    input wire c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [31:0] c_queue,c_slot,
    input wire [TICK_W-1:0] c_duration,c_cost,
    input wire [QUEUES-1:0] c_mask,
    input wire [DATA_W-1:0] c_data,input wire [TAG_W-1:0] c_tag,
    input wire c_enable,
    output reg r_valid,input wire r_ready,
    output reg [2:0] r_op,output reg [3:0] r_status,
    output reg [31:0] r_queue,r_slot,output reg [TAG_W-1:0] r_tag,
    output reg [31:0] r_count,
    output reg [TICK_W-1:0] r_head_cost,
    output reg [DATA_W-1:0] r_head_data,
    output reg [TAG_W-1:0] r_head_tag,
    output reg [31:0] r_active_slot,
    output reg [TICK_W-1:0] r_ticks_left,
    output reg r_running,r_busy,
    // Native irrevocable launch pulse, NOT a held ready/valid offer.
    input wire launch_accept,output wire launch,
    output wire [31:0] launch_queue,
    output wire [TICK_W-1:0] launch_cost,
    output wire [DATA_W-1:0] launch_data,
    output wire [TAG_W-1:0] launch_tag,
    output wire [31:0] launch_slot,
    output wire [TICK_W-1:0] launch_ticks_left,
    output reg running,
    output wire [31:0] active_slot,
    output reg [TICK_W-1:0] ticks_left,service_left,
    output wire [QUEUES-1:0] gate_mask,
    output wire [QUEUES*((DEPTH<2)?1:$clog2(DEPTH+1))-1:0] levels
);
    localparam integer CW=(DEPTH<2)?1:$clog2(DEPTH+1);
    localparam integer QW=(QUEUES<2)?1:$clog2(QUEUES);
    localparam integer SW=(SLOTS<2)?1:$clog2(SLOTS);
    localparam integer FW=TICK_W+DATA_W+TAG_W;
    localparam [3:0] OK=0,BAD_OP=1,BAD_QUEUE=2,BAD_SLOT=3,ZERO_VALUE=4,
                     FULL=5,BUSY=6,INCOMPLETE_PLAN=7,EMPTY=8;
    reg [TICK_W-1:0] staging_duration[0:SLOTS-1],active_duration[0:SLOTS-1];
    reg [QUEUES-1:0] staging_mask[0:SLOTS-1],active_mask[0:SLOTS-1];
    reg [SLOTS-1:0] staging_valid;
    reg plan_valid;
    reg [SW-1:0] slot;
    reg [QW-1:0] cursor;
    wire fire=c_valid&&c_ready;
    wire queue_valid=c_queue<QUEUES;
    wire [QUEUES-1:0] fifo_in_ready,fifo_out_valid;
    wire [QUEUES*FW-1:0] fifo_data;
    wire [QUEUES*CW-1:0] fifo_levels;
    wire [FW-1:0] command_head=fifo_data[c_queue*FW+:FW];
    wire [CW-1:0] command_count=fifo_levels[c_queue*CW+:CW];
    reg chosen_valid;
    reg [QW-1:0] chosen;
    integer offset,candidate;
    always @* begin
        chosen_valid=0;chosen=0;candidate=0;
        for(offset=0;offset<QUEUES;offset=offset+1) begin
            candidate=cursor+offset;
            if(candidate>=QUEUES) candidate=candidate-QUEUES;
            if(!chosen_valid&&gate_mask[candidate]&&fifo_out_valid[candidate]&&
               fifo_data[candidate*FW+:TICK_W]<=ticks_left) begin
                chosen_valid=1;chosen=QW'(candidate);
            end
        end
    end
    wire [FW-1:0] chosen_head=fifo_data[chosen*FW+:FW];
    assign c_ready=rst_n&&!r_valid;
    assign launch=rst_n&&running&&service_left==0&&launch_accept&&!fire&&chosen_valid;
    assign launch_queue={{(32-QW){1'b0}},chosen};
    assign launch_cost=chosen_head[0+:TICK_W];
    assign launch_data=chosen_head[TICK_W+:DATA_W];
    assign launch_tag=chosen_head[TICK_W+DATA_W+:TAG_W];
    assign launch_slot={{(32-SW){1'b0}},slot};
    assign launch_ticks_left=ticks_left;
    assign active_slot={{(32-SW){1'b0}},slot};
    assign gate_mask=plan_valid?active_mask[slot]:{QUEUES{1'b0}};
    assign levels=fifo_levels;
    genvar q;
    generate if(QUEUES<1||QUEUES>8||DEPTH<1||DEPTH>16||SLOTS<1||SLOTS>16||
                TICK_W<1||TICK_W>16||DATA_W<1||DATA_W>64||TAG_W<1||TAG_W>32) begin: invalid
        cyclic_gate_packet_scheduler_invalid_parameters__see_README invalid_parameters();
    end endgenerate
    generate for(q=0;q<QUEUES;q=q+1) begin: queues
        cip_sync_fifo #(.DATA_WIDTH(FW),.DEPTH(DEPTH)) queue (
            .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
            .in_valid(fire&&c_op==0&&c_queue==q&&c_cost!=0),.in_ready(fifo_in_ready[q]),
            .in_data({c_tag,c_data,c_cost}),
            .out_valid(fifo_out_valid[q]),
            .out_ready((launch&&chosen==q)||(fire&&c_op==5&&c_queue==q)),
            .out_data(fifo_data[q*FW+:FW]),.level(fifo_levels[q*CW+:CW]),.full(),.empty());
    end endgenerate
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            staging_valid<=0;plan_valid<=0;slot<=0;cursor<=0;running<=0;ticks_left<=0;service_left<=0;
            r_valid<=0;r_op<=0;r_status<=0;r_queue<=0;r_slot<=0;r_tag<=0;r_count<=0;
            r_head_cost<=0;r_head_data<=0;r_head_tag<=0;r_active_slot<=0;r_ticks_left<=0;r_running<=0;r_busy<=0;
        end else begin
            if(r_valid&&r_ready) r_valid<=0;
            if(service_left!=0) service_left<=service_left-1'b1;
            if(running) begin
                if(ticks_left==1) begin
                    if(slot==SLOTS-1) begin slot<=0;ticks_left<=active_duration[0];end
                    else begin slot<=slot+1'b1;ticks_left<=active_duration[slot+1'b1];end
                end else ticks_left<=ticks_left-1'b1;
            end
            if(launch) begin
                service_left<=launch_cost-1'b1;
                cursor<=(chosen==QUEUES-1)?{QW{1'b0}}:chosen+1'b1;
            end
            if(fire) begin
                r_valid<=1;r_op<=c_op;r_queue<=c_queue;r_slot<=c_slot;r_tag<=c_tag;r_status<=OK;
                r_active_slot<=active_slot;r_ticks_left<=ticks_left;r_running<=running;r_busy<=service_left!=0;
                r_count<=0;r_head_cost<=0;r_head_data<=0;r_head_tag<=0;
                if(queue_valid) begin
                    r_count<={{(32-CW){1'b0}},command_count};
                    if(fifo_out_valid[c_queue]) begin
                        r_head_cost<=command_head[0+:TICK_W];
                        r_head_data<=command_head[TICK_W+:DATA_W];
                        r_head_tag<=command_head[TICK_W+DATA_W+:TAG_W];
                    end
                end
                case(c_op)
                    0: if(!queue_valid) r_status<=BAD_QUEUE;
                       else if(c_cost==0) r_status<=ZERO_VALUE;
                       else if(!fifo_in_ready[c_queue]) r_status<=FULL;
                    1: if(c_slot>=SLOTS) r_status<=BAD_SLOT;
                       else if(c_duration==0) r_status<=ZERO_VALUE;
                       else begin
                           staging_duration[c_slot]<=c_duration;staging_mask[c_slot]<=c_mask;
                           staging_valid[c_slot]<=1;
                       end
                    2: if(running||service_left!=0) r_status<=BUSY;
                       else if(!(&staging_valid)) r_status<=INCOMPLETE_PLAN;
                       else begin
                           for(i=0;i<SLOTS;i=i+1) begin
                               active_duration[i]<=staging_duration[i];active_mask[i]<=staging_mask[i];
                           end
                           plan_valid<=1;slot<=0;ticks_left<=staging_duration[0];cursor<=0;
                       end
                    3: if(!c_enable) running<=0;
                       else if(running||service_left!=0) r_status<=BUSY;
                       else if(!plan_valid) r_status<=INCOMPLETE_PLAN;
                       else begin running<=1;slot<=0;ticks_left<=active_duration[0];cursor<=0;end
                    4: if(!queue_valid) r_status<=BAD_QUEUE;
                    5: if(!queue_valid) r_status<=BAD_QUEUE;
                       else if(!fifo_out_valid[c_queue]) r_status<=EMPTY;
                    default:r_status<=BAD_OP;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
