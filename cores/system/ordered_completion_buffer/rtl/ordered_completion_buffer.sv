// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Tagged out-of-order completion with issue-order retirement; one clock.
module ordered_completion_buffer #(
    parameter integer DEPTH=8,
    parameter integer DATA_W=32,
    parameter integer META_W=16,
    localparam integer TAG_W=(DEPTH<2)?1:$clog2(DEPTH),
    localparam integer COUNT_W=$clog2(DEPTH+1)
)(
    input wire clk, rst,
    input wire a_valid,
    output wire a_ready,
    input wire [META_W-1:0] a_meta,
    output wire [TAG_W-1:0] a_tag,
    input wire c_valid,
    output wire c_ready,
    input wire [TAG_W-1:0] c_tag,
    input wire [DATA_W-1:0] c_data,
    input wire c_error,
    output reg c_rejected,
    output wire m_valid,
    input wire m_ready,
    output reg [META_W-1:0] m_meta,
    output reg [DATA_W-1:0] m_data,
    output reg m_error,
    output wire [COUNT_W-1:0] occupancy
);
    generate if(DEPTH<1 || DEPTH>64 || DATA_W<1 || DATA_W>256 || META_W<1 || META_W>64)
        begin: g_invalid
            ordered_completion_buffer_invalid_parameters invalid_configuration();
        end
    endgenerate

    reg [DEPTH-1:0] allocated, completed;
    reg [TAG_W-1:0] head, tail;
    reg [COUNT_W-1:0] count;
    reg output_valid;
    reg [META_W-1:0] metadata[0:DEPTH-1];
    reg [DATA_W:0] results[0:DEPTH-1];
    wire retire = m_valid && m_ready;
    wire allocate = a_valid && a_ready;
    wire complete = c_valid && c_ready;
    reg completion_ok;

    // Avoid any array/vector indexing with an out-of-range tag.
    always @* begin
        completion_ok=1'b0;
        if(c_tag<DEPTH)
            completion_ok=allocated[c_tag] && !completed[c_tag];
    end
    wire fetch = !rst && !output_valid && count!=0 && completed[head];
    assign a_ready = !rst && ((count<DEPTH) || retire);
    assign a_tag = tail;
    assign c_ready = !rst;
    assign m_valid = !rst && output_valid;
    assign occupancy = count;

    // Separate memories, each one write port and one synchronous read port.
    // Only a completed, allocated head may be fetched, so writes cannot
    // collide with its read. No payload RAM is reset.
    always @(posedge clk) begin
        if(allocate) metadata[tail]<=a_meta;
        if(complete && completion_ok) results[c_tag]<={c_error,c_data};
        if(fetch) begin
            m_meta<=metadata[head];
            {m_error,m_data}<=results[head];
        end
    end

    always @(posedge clk) begin
        if(rst) begin
            allocated<=0;
            completed<=0;
            head<=0;tail<=0;count<=0;
            output_valid<=0;
            c_rejected<=0;
        end else begin
            c_rejected<=0;
            if(fetch) output_valid<=1;
            if(retire) begin
                output_valid<=0;
                allocated[head]<=0;
                completed[head]<=0;
                head<=(head==DEPTH-1)?0:head+1'b1;
            end
            // On a full buffer, a retiring head and new tail may be the
            // same slot. Allocation owns that slot after the edge.
            if(allocate) begin
                allocated[tail]<=1;
                completed[tail]<=0;
                tail<=(tail==DEPTH-1)?0:tail+1'b1;
            end
            if(complete) begin
                if(completion_ok) completed[c_tag]<=1;
                else c_rejected<=1;
            end
            case({allocate,retire})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:begin end
            endcase
        end
    end
endmodule
