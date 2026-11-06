// SPDX-License-Identifier: Apache-2.0
`default_nettype none
module soupbintcp_session_rx #(
    parameter integer FIFO_DEPTH = 128,
    parameter integer TAG_W = 8
)(
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire [7:0] s_data, input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output wire [7:0] m_data, output wire m_last,
    output wire [63:0] m_sequence, output wire [79:0] m_session,
    output wire [TAG_W-1:0] m_tag,
    output wire r_valid, input wire r_ready,
    output wire [2:0] r_status, output wire [7:0] r_type, output wire [7:0] r_reason,
    output wire [15:0] r_length, output wire [15:0] r_payload_bytes,
    output wire [63:0] r_sequence, output wire [63:0] r_next,
    output wire [79:0] r_session, output wire [TAG_W-1:0] r_tag,
    output wire r_logged, output wire r_closed, output wire r_faulted,
    output wire r_exhausted
);
    generate
        if (FIFO_DEPTH < 32 || FIFO_DEPTH > 4096 ||
            (FIFO_DEPTH & (FIFO_DEPTH-1)) != 0 || TAG_W < 1 || TAG_W > 32) begin : bad_parameters
            SOUP_RX_REQUIRES_POWER2_DEPTH32_TO4096_TAG1_TO32 invalid_parameters();
        end
    endgenerate
    localparam [3:0] LEN_HI=0, LEN_LO=1, TYPE=2, BODY=3,
                     WAIT_FIFO=4, DRAIN_FIFO=5, COMPLETE=6;
    localparam [2:0] OK=0, BAD_TYPE=1, BAD_LENGTH=2, CAPACITY=3,
                     BAD_FIELD=4, SESSION_STATE=5, SEQUENCE_EXHAUSTED=6;
    reg [3:0] state;
    reg [15:0] length_reg, remaining, body_index;
    reg [7:0] type_reg, reason_reg;
    reg [2:0] error_reg;
    reg [TAG_W-1:0] tag_reg;
    reg logged, closed, faulted, exhausted;
    reg [79:0] session_reg, login_session, frame_session;
    reg [63:0] next_reg, login_sequence, frame_sequence;
    reg digit_seen, buffered, skip_type;

    wire f_ready, f_valid, f_last, f_good, f_bad, f_overflow;
    wire [7:0] f_data;
    wire input_state = state==LEN_HI || state==LEN_LO || state==TYPE || state==BODY;
    wire need_fifo = (state==TYPE && s_data!=8'h2b && start_error==OK) ||
                     (state==BODY && buffered);
    assign s_ready = !rst && !faulted && !closed && input_state && (!need_fifo || f_ready);
    wire take = s_valid && s_ready;

    reg [2:0] start_error;
    always @* begin
        start_error = OK;
        case (s_data)
            8'h2b: start_error=OK; // Debug is ignored even before login.
            8'h41: begin
                if (length_reg!=16'd31) start_error=BAD_LENGTH;
                else if (logged) start_error=SESSION_STATE;
            end
            8'h4a: begin
                if (length_reg!=16'd2) start_error=BAD_LENGTH;
                else if (logged) start_error=SESSION_STATE;
            end
            8'h48,8'h5a: begin
                if (length_reg!=16'd1) start_error=BAD_LENGTH;
                else if (!logged) start_error=SESSION_STATE;
            end
            8'h53: begin
                if (length_reg>FIFO_DEPTH) start_error=CAPACITY;
                else if (!logged) start_error=SESSION_STATE;
                else if (exhausted) start_error=SEQUENCE_EXHAUSTED;
            end
            default: start_error=BAD_TYPE;
        endcase
    end

    // ASCII parsing is exact integer arithmetic. 68 bits cover 10*u64+9.
    wire char_digit = s_data>=8'h30 && s_data<=8'h39;
    wire [3:0] digit = s_data[3:0];
    wire [67:0] decimal_step = ({4'b0,login_sequence}<<3) +
                              ({4'b0,login_sequence}<<1) + {64'b0,digit};
    reg [63:0] parsed_sequence;
    reg parsed_seen;
    reg [2:0] body_error;
    always @* begin
        parsed_sequence=login_sequence;
        parsed_seen=digit_seen;
        body_error=error_reg;
        if (type_reg==8'h41 && body_index>=16'd11) begin
            if (char_digit) begin
                parsed_sequence=decimal_step[63:0];
                parsed_seen=1'b1;
                if (decimal_step[67:64]!=0) body_error=BAD_FIELD;
            end else if (s_data!=8'h20 || digit_seen) body_error=BAD_FIELD;
            if (remaining==16'd1 && (!parsed_seen || parsed_sequence==0)) body_error=BAD_FIELD;
        end
        if (type_reg==8'h4a && s_data!=8'h41 && s_data!=8'h53) body_error=BAD_FIELD;
    end

    wire f_input_valid = !rst && s_valid && !faulted && !closed &&
        ((state==TYPE && s_data!=8'h2b && start_error==OK) || (state==BODY && buffered));
    wire f_input_last = state==TYPE ? length_reg==16'd1 : remaining==16'd1;
    wire f_input_bad = state==TYPE ? start_error!=OK : body_error!=OK;
    wire f_output_ready = !rst && state==DRAIN_FIFO &&
        (skip_type || type_reg!=8'h53 || m_ready);
    soup_rx_axis_fifo #(
        .DEPTH(FIFO_DEPTH), .DATA_WIDTH(8), .KEEP_ENABLE(0), .KEEP_WIDTH(1),
        .LAST_ENABLE(1), .ID_ENABLE(0), .ID_WIDTH(1),
        .DEST_ENABLE(0), .DEST_WIDTH(1), .USER_ENABLE(1), .USER_WIDTH(1),
        .RAM_PIPELINE(1), .OUTPUT_FIFO_ENABLE(0), .FRAME_FIFO(1),
        .USER_BAD_FRAME_VALUE(1'b1), .USER_BAD_FRAME_MASK(1'b1),
        .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(1), .DROP_WHEN_FULL(0),
        .MARK_WHEN_FULL(0), .PAUSE_ENABLE(0), .FRAME_PAUSE(1)
    ) frame_store (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_data), .s_axis_tkeep(1'b1), .s_axis_tvalid(f_input_valid),
        .s_axis_tready(f_ready), .s_axis_tlast(f_input_last),
        .s_axis_tid(1'b0), .s_axis_tdest(1'b0), .s_axis_tuser(f_input_bad),
        .m_axis_tdata(f_data), .m_axis_tkeep(), .m_axis_tvalid(f_valid),
        .m_axis_tready(f_output_ready), .m_axis_tlast(f_last),
        .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .pause_req(1'b0), .pause_ack(), .status_depth(), .status_depth_commit(),
        .status_overflow(f_overflow), .status_bad_frame(f_bad), .status_good_frame(f_good)
    );

    assign m_valid = !rst && state==DRAIN_FIFO && !skip_type && type_reg==8'h53 && f_valid;
    assign m_data=f_data;
    assign m_last=f_last;
    assign m_sequence=frame_sequence;
    assign m_session=frame_session;
    assign m_tag=tag_reg;
    assign r_valid=!rst && state==COMPLETE;
    assign r_status=error_reg;
    assign r_type=type_reg;
    assign r_reason=type_reg==8'h4a && error_reg==OK ? reason_reg : 8'd0;
    assign r_length=length_reg;
    assign r_payload_bytes=length_reg==0 ? 16'd0 : length_reg-16'd1;
    assign r_sequence=type_reg==8'h53 && error_reg==OK ? frame_sequence : 64'd0;
    assign r_next=next_reg;
    assign r_session=session_reg;
    assign r_tag=tag_reg;
    assign r_logged=logged;
    assign r_closed=closed;
    assign r_faulted=faulted;
    assign r_exhausted=exhausted;

    always @(posedge clk) begin
        if (rst) begin
            state<=LEN_HI; length_reg<=0; remaining<=0; body_index<=0;
            type_reg<=0; reason_reg<=0; error_reg<=OK; tag_reg<=0;
            logged<=0; closed<=0; faulted<=0; exhausted<=0;
            session_reg<=0; login_session<=0; frame_session<=0;
            next_reg<=0; login_sequence<=0; frame_sequence<=0;
            digit_seen<=0; buffered<=0; skip_type<=0;
        end else begin
            if (take) begin
                case (state)
                    LEN_HI: begin
                        length_reg<={s_data,8'b0}; tag_reg<=s_tag;
                        type_reg<=0; error_reg<=OK; buffered<=0;
                        frame_sequence<=0; frame_session<=session_reg;
                        state<=LEN_LO;
                    end
                    LEN_LO: begin
                        length_reg[7:0]<=s_data;
                        if ({length_reg[15:8],s_data}==0) begin
                            error_reg<=BAD_LENGTH; faulted<=1; state<=COMPLETE;
                        end else state<=TYPE;
                    end
                    TYPE: begin
                        type_reg<=s_data; error_reg<=start_error;
                        remaining<=length_reg-16'd1; body_index<=16'd1;
                        buffered<=s_data!=8'h2b && start_error==OK;
                        frame_sequence<=next_reg; frame_session<=session_reg;
                        login_sequence<=0; login_session<=0; digit_seen<=0; reason_reg<=0;
                        if (length_reg==16'd1) begin
                            if (start_error!=OK) begin
                                faulted<=1; state<=COMPLETE;
                            end else if (s_data==8'h2b) state<=COMPLETE;
                            else state<=WAIT_FIFO;
                        end else state<=BODY;
                    end
                    BODY: begin
                        remaining<=remaining-16'd1; body_index<=body_index+16'd1;
                        if (type_reg==8'h41 && buffered) begin
                            if (body_index<=16'd10) login_session<={login_session[71:0],s_data};
                            else begin
                                login_sequence<=parsed_sequence;
                                digit_seen<=parsed_seen;
                            end
                        end
                        if (type_reg==8'h4a && buffered) reason_reg<=s_data;
                        // Error priority determined at TYPE is preserved for skipped frames.
                        if (buffered) error_reg<=body_error;
                        if (remaining==16'd1) begin
                            if (buffered) state<=WAIT_FIFO;
                            else begin
                                if (error_reg!=OK) faulted<=1;
                                state<=COMPLETE;
                            end
                        end
                    end
                    default: begin end
                endcase
            end
            if (state==WAIT_FIFO) begin
                if (f_bad || f_overflow) begin
                    if (f_overflow) error_reg<=CAPACITY;
                    faulted<=1; state<=COMPLETE;
                end else if (f_good) begin
                    skip_type<=1; state<=DRAIN_FIFO;
                    case (type_reg)
                        8'h41: begin
                            session_reg<=login_session; next_reg<=login_sequence;
                            logged<=1; exhausted<=0;
                        end
                        8'h4a,8'h5a: begin logged<=0; closed<=1; end
                        8'h53: begin
                            if (&next_reg) exhausted<=1;
                            else next_reg<=next_reg+64'd1;
                        end
                        default: begin end
                    endcase
                end
            end
            if (state==DRAIN_FIFO && f_valid && f_output_ready) begin
                skip_type<=0;
                if (f_last) state<=COMPLETE;
            end
            if (state==COMPLETE && r_ready) state<=LEN_HI;
        end
    end
endmodule
`default_nettype wire
