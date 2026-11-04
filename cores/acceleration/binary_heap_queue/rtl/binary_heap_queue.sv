// SPDX-License-Identifier: Apache-2.0
// One outstanding command, single synchronous read / write heap storage.
module binary_heap_queue #(
    parameter integer KEY_W = 16,
    parameter integer DATA_W = 32,
    parameter integer CAPACITY = 32,
    parameter integer SIGNED_KEY = 1,
    localparam integer COUNT_W = (CAPACITY < 2) ? 1 : $clog2(CAPACITY+1)
) (
    input  wire clk,
    input  wire rst,
    input  wire s_valid,
    output wire s_ready,
    input  wire [1:0] s_op, // 0 push, 1 pop, 2 peek, 3 clear
    input  wire [KEY_W-1:0] s_key,
    input  wire [DATA_W-1:0] s_data,
    output wire m_valid,
    input  wire m_ready,
    output reg  [1:0] m_op,
    output reg  [1:0] m_status, // 0 OK, 1 FULL, 2 EMPTY
    output reg  [KEY_W-1:0] m_key,
    output reg  [DATA_W-1:0] m_data,
    output wire [COUNT_W-1:0] m_count
);
    localparam integer ENTRY_W = KEY_W + DATA_W;
    localparam [3:0] IDLE=0, RESPONSE=1, PUSH_READ=2, PUSH_COMPARE=3,
        ROOT_READ=4, ROOT_CAPTURE=5, LAST_READ=6, LAST_CAPTURE=7,
        LEFT_READ=8, LEFT_CAPTURE=9, RIGHT_READ=10, RIGHT_CAPTURE=11,
        CHILD_COMPARE=12;
    localparam [COUNT_W-1:0] CAP_COUNT = COUNT_W'(CAPACITY);
    reg [3:0] state;
    reg [COUNT_W-1:0] count, position, child_position;
    reg [ENTRY_W-1:0] item, child_item;
    reg is_pop;

    // Index zero is unused. Only written entries are ever read; reset clears
    // ownership (count), not the memory, allowing RAM inference.
    reg [ENTRY_W-1:0] heap [1:CAPACITY];
    reg [ENTRY_W-1:0] read_item;
    reg read_enable, write_enable;
    reg [COUNT_W-1:0] read_address, write_address;
    reg [ENTRY_W-1:0] write_item;
    wire [COUNT_W:0] left_position = {1'b0, position} << 1;
    wire [COUNT_W:0] right_position = left_position + {{COUNT_W{1'b0}},1'b1};

    // Key ascending, then unsigned payload ascending. Identical entries are
    // interchangeable; this queue does not promise insertion-order stability.
    function automatic before_entry(input [ENTRY_W-1:0] a, b);
        begin
            if (a[ENTRY_W-1:DATA_W] == b[ENTRY_W-1:DATA_W])
                before_entry = a[DATA_W-1:0] < b[DATA_W-1:0];
            else if (SIGNED_KEY != 0)
                before_entry = $signed(a[ENTRY_W-1:DATA_W]) < $signed(b[ENTRY_W-1:DATA_W]);
            else
                before_entry = a[ENTRY_W-1:DATA_W] < b[ENTRY_W-1:DATA_W];
        end
    endfunction

    // A shared lexicographic comparator serves the serialized sift phases.
    reg [ENTRY_W-1:0] compare_a, compare_b;
    wire compare_before = before_entry(compare_a, compare_b);
    always @* begin
        compare_a = item;
        compare_b = read_item;
        if (state == RIGHT_CAPTURE) begin
            compare_a = read_item;
            compare_b = child_item;
        end else if (state == CHILD_COMPARE) begin
            compare_a = child_item;
            compare_b = item;
        end
    end

    assign s_ready = !rst && (state == IDLE);
    assign m_valid = !rst && (state == RESPONSE);
    assign m_count = count;

    always @* begin
        read_enable = 1'b0;
        read_address = {{(COUNT_W-1){1'b0}},1'b1};
        write_enable = 1'b0;
        write_address = position;
        write_item = item;
        if (!rst) begin
            case (state)
                PUSH_READ: begin
                    if (position == 1) write_enable = 1'b1;
                    else begin
                        read_enable = 1'b1;
                        read_address = position >> 1;
                    end
                end
                PUSH_COMPARE: begin
                    write_enable = 1'b1;
                    if (compare_before) write_item = read_item;
                end
                ROOT_READ: read_enable = 1'b1;
                LAST_READ: begin read_enable = 1'b1; read_address = count; end
                LEFT_READ: begin
                    if (left_position > {1'b0,count}) write_enable = 1'b1;
                    else begin
                        read_enable = 1'b1;
                        read_address = left_position[COUNT_W-1:0];
                    end
                end
                RIGHT_READ: begin
                    read_enable = 1'b1;
                    read_address = right_position[COUNT_W-1:0];
                end
                CHILD_COMPARE: begin
                    write_enable = 1'b1;
                    if (compare_before) write_item = child_item;
                end
                default: begin end
            endcase
        end
    end

    always @(posedge clk) begin
        if (read_enable) read_item <= heap[read_address];
        if (write_enable) heap[write_address] <= write_item;
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            count <= 0;
            position <= 0;
            child_position <= 0;
            item <= 0;
            child_item <= 0;
            is_pop <= 0;
            m_op <= 0;
            m_status <= 0;
            m_key <= 0;
            m_data <= 0;
        end else begin
            case (state)
                IDLE: if (s_valid) begin
                    m_op <= s_op;
                    m_status <= 0;
                    m_key <= 0;
                    m_data <= 0;
                    case (s_op)
                        0: begin
                            m_key <= s_key;
                            m_data <= s_data;
                            if (count == CAP_COUNT) begin
                                m_status <= 1;
                                state <= RESPONSE;
                            end else begin
                                item <= {s_key,s_data};
                                position <= count + 1'b1;
                                count <= count + 1'b1;
                                state <= PUSH_READ;
                            end
                        end
                        1,2: begin
                            if (count == 0) begin m_status <= 2; state <= RESPONSE; end
                            else begin is_pop <= (s_op == 1); state <= ROOT_READ; end
                        end
                        3: begin count <= 0; state <= RESPONSE; end
                    endcase
                end
                RESPONSE: if (m_ready) state <= IDLE;
                PUSH_READ: begin
                    if (position == 1) state <= RESPONSE;
                    else state <= PUSH_COMPARE;
                end
                PUSH_COMPARE: begin
                    if (compare_before) begin
                        position <= position >> 1;
                        state <= PUSH_READ;
                    end else state <= RESPONSE;
                end
                ROOT_READ: state <= ROOT_CAPTURE;
                ROOT_CAPTURE: begin
                    m_key <= read_item[ENTRY_W-1:DATA_W];
                    m_data <= read_item[DATA_W-1:0];
                    if (!is_pop) state <= RESPONSE;
                    else if (count == 1) begin count <= 0; state <= RESPONSE; end
                    else state <= LAST_READ;
                end
                LAST_READ: state <= LAST_CAPTURE;
                LAST_CAPTURE: begin
                    item <= read_item;
                    count <= count - 1'b1;
                    position <= 1;
                    state <= LEFT_READ;
                end
                LEFT_READ: begin
                    if (left_position > {1'b0,count}) state <= RESPONSE;
                    else state <= LEFT_CAPTURE;
                end
                LEFT_CAPTURE: begin
                    child_item <= read_item;
                    child_position <= left_position[COUNT_W-1:0];
                    if (right_position <= {1'b0,count}) state <= RIGHT_READ;
                    else state <= CHILD_COMPARE;
                end
                RIGHT_READ: state <= RIGHT_CAPTURE;
                RIGHT_CAPTURE: begin
                    if (compare_before) begin
                        child_item <= read_item;
                        child_position <= right_position[COUNT_W-1:0];
                    end
                    state <= CHILD_COMPARE;
                end
                CHILD_COMPARE: begin
                    if (compare_before) begin
                        position <= child_position;
                        state <= LEFT_READ;
                    end else state <= RESPONSE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
