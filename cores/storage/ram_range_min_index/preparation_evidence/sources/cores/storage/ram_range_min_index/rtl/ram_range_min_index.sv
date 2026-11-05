// Original ANSCORE contribution, Apache-2.0. See LICENSE and SOURCES.md.
module ram_range_min_index #(
    parameter integer BUCKETS = 64,
    parameter integer VALUE_W = 16,
    parameter integer TAG_W = 8
) (
    input wire clk, input wire rst_n,
    input wire c_valid, output wire c_ready,
    input wire [1:0] c_op,
    input wire [31:0] c_lo, input wire [31:0] c_hi,
    input wire [VALUE_W-1:0] c_value,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid, input wire r_ready,
    output wire [1:0] r_op, output wire [1:0] r_status,
    output wire [31:0] r_index,
    output wire [VALUE_W-1:0] r_value,
    output wire [TAG_W-1:0] r_tag
);
generate
if (BUCKETS < 1 || BUCKETS > 256 || VALUE_W < 1 || VALUE_W > 32 ||
    TAG_W < 1 || TAG_W > 32) begin : g_invalid
    ram_range_min_index_invalid_parameters__see_README invalid_parameters();
    assign c_ready = 1'b0;
    assign r_valid = 1'b0;
    assign r_op = 0; assign r_status = 0; assign r_index = 0;
    assign r_value = 0; assign r_tag = 0;
end else begin : g_legal
    localparam integer H = $clog2(BUCKETS);
    localparam integer P = 1 << H;
    localparam integer IW = H > 0 ? H : 1;
    localparam integer NW = H+1;
    localparam integer SPW = H > 0 ? $clog2(H+1) : 1;
    localparam integer ROW_W = 8*((VALUE_W+IW+2+7)/8);
    localparam [4:0] BOOT=0, BOOT_DONE=1, IDLE=2, VISIT=3,
        NODE=4, PUSH_RIGHT=5, DESCEND=6, RETURN_NODE=7,
        PULL_LEFT=8, PULL_SAVE=9, PULL_MERGE=10, RESPONSE=11,
        MEM_REQ=12, MEM_RSP=13, CLEAR_DONE=14;
    reg [4:0] state, bus_return;
    reg [1:0] op;
    reg [31:0] low_q, high_q;
    reg [VALUE_W-1:0] value_q;
    reg [TAG_W-1:0] tag_q;
    reg [NW-1:0] node, node_lo, span;
    reg [SPW-1:0] sp;
    reg [NW-1:0] stack_node [0:H];
    reg [NW-1:0] stack_lo [0:H];
    reg [NW-1:0] stack_span [0:H];
    reg stack_right [0:H];
    reg bus_write;
    reg [NW-1:0] bus_addr;
    reg [ROW_W-1:0] bus_data, row_q;
    reg [VALUE_W-1:0] uniform_value, left_value, best_value;
    reg [IW-1:0] left_index, best_index;
    reg left_valid, best_valid;
    reg valid_q;
    reg [1:0] status_q;
    reg [31:0] index_q;
    reg [VALUE_W-1:0] result_q;
    wire req_ready, rsp_valid, rsp_error;
    wire [ROW_W-1:0] rsp_data;
    wire [NW-1:0] half_span = span >> 1;
    wire [NW:0] end_ext = {1'b0,node_lo}+{1'b0,span}-1'b1;
    wire [31:0] last_valid = end_ext >= BUCKETS ? BUCKETS-1 : end_ext;
    wire disjoint = node_lo >= BUCKETS || node_lo > high_q || end_ext < low_q;
    wire covered = low_q <= node_lo && high_q >= last_valid;
    wire [NW-1:0] right_lo = node_lo+half_span;
    wire [VALUE_W-1:0] row_value = row_q[VALUE_W-1:0];
    wire [IW-1:0] row_index = row_q[VALUE_W +: IW];
    wire row_lazy = row_q[VALUE_W+IW];
    wire row_valid = row_q[VALUE_W+IW+1];
    wire [31:0] query_index = row_lazy ?
        (low_q > node_lo ? low_q : node_lo) : row_index;
    wire choose_left = left_valid && (!row_valid || left_value < row_value ||
        (left_value == row_value && left_index <= row_index));
    function automatic [ROW_W-1:0] pack;
        input [VALUE_W-1:0] v;
        input [IW-1:0] i;
        input lazy;
        input present;
        begin
            pack = {ROW_W{1'b0}};
            pack[VALUE_W-1:0] = v;
            pack[VALUE_W +: IW] = i;
            pack[VALUE_W+IW] = lazy;
            pack[VALUE_W+IW+1] = present;
        end
    endfunction
    assign c_ready = rst_n && state == IDLE;
    assign r_valid = rst_n && valid_q;
    assign r_op = op; assign r_status = status_q;
    assign r_index = index_q; assign r_value = result_q; assign r_tag = tag_q;
    cip_sync_sp_ram #(.DATA_WIDTH(ROW_W), .ADDR_WIDTH(NW), .DEPTH(2*P)) ram (
        .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
        .req_valid(rst_n && state == MEM_REQ), .req_ready(req_ready),
        .req_write(bus_write), .req_addr(bus_addr), .req_wdata(bus_data),
        .req_wstrb({ROW_W/8{1'b1}}),
        .rsp_valid(rsp_valid), .rsp_ready(rst_n && state == MEM_RSP),
        .rsp_rdata(rsp_data), .rsp_error(rsp_error)
    );
    // Invalid RAM response payloads and stale stack rows are overwritten before use.
    // Reset writes only root; lazy ancestors protect all stale descendant data.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= BOOT; bus_return <= BOOT_DONE;
            op <= 0; low_q <= 0; high_q <= 0; value_q <= 0; tag_q <= 0;
            node <= 1; node_lo <= 0; span <= P; sp <= 0;
            bus_write <= 0; bus_addr <= 0; bus_data <= 0;
            valid_q <= 0; status_q <= 0; index_q <= 0; result_q <= 0;
            best_valid <= 0;
        end else begin
            case (state)
            BOOT: begin
                bus_write <= 1; bus_addr <= 1;
                bus_data <= pack(0,0,1'b1,1'b1);
                bus_return <= BOOT_DONE; state <= MEM_REQ;
            end
            BOOT_DONE: state <= IDLE;
            IDLE: if (c_valid) begin
                op <= c_op; tag_q <= c_tag;
                low_q <= c_lo; high_q <= c_hi; value_q <= c_value;
                status_q <= 0; index_q <= 0; result_q <= 0;
                best_valid <= 0; sp <= 0; node <= 1; node_lo <= 0; span <= P;
                if (c_op == 3) begin
                    status_q <= 2; valid_q <= 1; state <= RESPONSE;
                end else if (c_op == 2) begin
                    bus_write <= 1; bus_addr <= 1;
                    bus_data <= pack(0,0,1'b1,1'b1);
                    bus_return <= CLEAR_DONE; state <= MEM_REQ;
                end else if (c_lo > c_hi || c_hi >= BUCKETS) begin
                    status_q <= 1; valid_q <= 1; state <= RESPONSE;
                end else state <= VISIT;
            end
            VISIT: begin
                if (disjoint) state <= RETURN_NODE;
                else if (op == 0 && covered) begin
                    bus_write <= 1; bus_addr <= node;
                    bus_data <= pack(value_q,node_lo[IW-1:0],1'b1,1'b1);
                    bus_return <= RETURN_NODE; state <= MEM_REQ;
                end else begin
                    bus_write <= 0; bus_addr <= node;
                    bus_return <= NODE; state <= MEM_REQ;
                end
            end
            NODE: begin
                if (op == 1 && (covered || row_lazy)) begin
                    if (row_valid && (!best_valid || row_value < best_value ||
                        (row_value == best_value && query_index < best_index))) begin
                        best_valid <= 1; best_value <= row_value;
                        best_index <= query_index[IW-1:0];
                    end
                    state <= RETURN_NODE;
                end else if (op == 0 && row_lazy) begin
                    uniform_value <= row_value;
                    bus_write <= 1; bus_addr <= node << 1;
                    bus_data <= pack(row_value,node_lo[IW-1:0],1'b1,node_lo < BUCKETS);
                    bus_return <= PUSH_RIGHT; state <= MEM_REQ;
                end else state <= DESCEND;
            end
            PUSH_RIGHT: begin
                bus_write <= 1; bus_addr <= (node << 1)+1'b1;
                bus_data <= pack(uniform_value,right_lo[IW-1:0],1'b1,right_lo < BUCKETS);
                bus_return <= DESCEND; state <= MEM_REQ;
            end
            DESCEND: begin
                stack_node[sp] <= node; stack_lo[sp] <= node_lo;
                stack_span[sp] <= span; stack_right[sp] <= 0;
                sp <= sp+1'b1; node <= node << 1;
                span <= half_span; state <= VISIT;
            end
            RETURN_NODE: begin
                if (sp == 0) begin
                    valid_q <= 1; state <= RESPONSE;
                    index_q <= op == 0 ? low_q : best_index;
                    result_q <= op == 0 ? value_q : best_value;
                end else if (!stack_right[sp-1'b1]) begin
                    stack_right[sp-1'b1] <= 1;
                    node <= (stack_node[sp-1'b1] << 1)+1'b1;
                    node_lo <= stack_lo[sp-1'b1]+(stack_span[sp-1'b1] >> 1);
                    span <= stack_span[sp-1'b1] >> 1; state <= VISIT;
                end else begin
                    node <= stack_node[sp-1'b1]; node_lo <= stack_lo[sp-1'b1];
                    span <= stack_span[sp-1'b1]; sp <= sp-1'b1;
                    state <= op == 0 ? PULL_LEFT : RETURN_NODE;
                end
            end
            PULL_LEFT: begin
                bus_write <= 0; bus_addr <= node << 1;
                bus_return <= PULL_SAVE; state <= MEM_REQ;
            end
            PULL_SAVE: begin
                left_value <= row_value; left_index <= row_index; left_valid <= row_valid;
                bus_write <= 0; bus_addr <= (node << 1)+1'b1;
                bus_return <= PULL_MERGE; state <= MEM_REQ;
            end
            PULL_MERGE: begin
                bus_write <= 1; bus_addr <= node;
                bus_data <= pack(choose_left ? left_value : row_value,
                    choose_left ? left_index : row_index,1'b0,left_valid || row_valid);
                bus_return <= RETURN_NODE; state <= MEM_REQ;
            end
            MEM_REQ: if (req_ready) state <= MEM_RSP;
            MEM_RSP: if (rsp_valid) begin
                if (!bus_write) row_q <= rsp_data;
                state <= bus_return;
            end
            CLEAR_DONE: begin
                valid_q <= 1; state <= RESPONSE;
            end
            RESPONSE: if (r_ready) begin
                valid_q <= 0; state <= IDLE;
            end
            default: state <= BOOT;
            endcase
        end
    end
end
endgenerate
endmodule
