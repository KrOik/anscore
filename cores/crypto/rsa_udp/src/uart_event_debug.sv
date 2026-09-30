module uart_event_debug (
    input clk,
    input rst_n,
    input event_boot,
    input event_frame,
    input event_ip,
    input event_udp_proto,
    input event_payload_start,
    input event_arp,
    input event_udp,
    input event_ok,
    input event_error,
    input event_tx,
    input event_resp,
    input [255:0] resp_data,
    output uart_tx_pin
);

    localparam [3:0] MSG_NONE = 4'd0;
    localparam [3:0] MSG_BOOT = 4'd1;
    localparam [3:0] MSG_FRAME = 4'd2;
    localparam [3:0] MSG_IP = 4'd3;
    localparam [3:0] MSG_UDP_PROTO = 4'd4;
    localparam [3:0] MSG_PAYLOAD_START = 4'd5;
    localparam [3:0] MSG_ARP = 4'd6;
    localparam [3:0] MSG_UDP = 4'd7;
    localparam [3:0] MSG_OK = 4'd8;
    localparam [3:0] MSG_ER = 4'd9;
    localparam [3:0] MSG_TX = 4'd10;
    localparam [3:0] MSG_RESP = 4'd11;

    reg [10:0] pending;
    reg [3:0] msg;
    reg [6:0] idx;
    reg waiting_ready_low;
    reg msg_done_pending;
    reg tx_valid;
    reg [7:0] tx_data;
    reg [255:0] resp_dump;
    wire tx_ready;
    wire tx_busy;

    uart_tx #(
        .CLK_FRE(50),
        .BAUD_RATE(115200)
    ) uart_inst (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(tx_data),
        .tx_data_valid(tx_valid),
        .tx_data_ready(tx_ready),
        .tx_pin(uart_tx_pin),
        .tx_busy(tx_busy)
    );

    function automatic [7:0] hex_nybble(input [3:0] nib);
        begin
            hex_nybble = (nib < 4'd10) ? (8'h30 + nib) : (8'h41 + nib - 4'd10);
        end
    endfunction

    function automatic [7:0] msg_byte(input [3:0] which, input [6:0] pos);
        begin
            case (which)
                MSG_BOOT: begin
                    if (pos == 0) msg_byte = "B";
                    else if (pos == 1) msg_byte = "O";
                    else if (pos == 2) msg_byte = "O";
                    else if (pos == 3) msg_byte = "T";
                        else msg_byte = 8'h0A;
                end
                MSG_FRAME: begin
                    if (pos == 0) msg_byte = "F";
                    else if (pos == 1) msg_byte = "R";
                    else msg_byte = 8'h0A;
                end
                MSG_IP: begin
                    if (pos == 0) msg_byte = "I";
                    else if (pos == 1) msg_byte = "P";
                    else msg_byte = 8'h0A;
                end
                MSG_UDP_PROTO: begin
                    if (pos == 0) msg_byte = "U";
                    else if (pos == 1) msg_byte = "0";
                    else msg_byte = 8'h0A;
                end
                MSG_PAYLOAD_START: begin
                    if (pos == 0) msg_byte = "P";
                    else if (pos == 1) msg_byte = "S";
                    else msg_byte = 8'h0A;
                end
                MSG_ARP: begin
                    if (pos == 0) msg_byte = "A";
                    else if (pos == 1) msg_byte = "R";
                    else if (pos == 2) msg_byte = "P";
                    else msg_byte = 8'h0A;
                end
                MSG_UDP: begin
                    if (pos == 0) msg_byte = "U";
                    else if (pos == 1) msg_byte = "D";
                    else if (pos == 2) msg_byte = "P";
                    else msg_byte = 8'h0A;
                end
                MSG_OK: begin
                    if (pos == 0) msg_byte = "O";
                    else if (pos == 1) msg_byte = "K";
                    else msg_byte = 8'h0A;
                end
                MSG_ER: begin
                    if (pos == 0) msg_byte = "E";
                    else if (pos == 1) msg_byte = "R";
                    else msg_byte = 8'h0A;
                end
                MSG_TX: begin
                    if (pos == 0) msg_byte = "T";
                    else if (pos == 1) msg_byte = "X";
                    else msg_byte = 8'h0A;
                end
                MSG_RESP: begin
                    if (pos == 0) msg_byte = "C";
                    else if (pos == 1) msg_byte = "T";
                    else if (pos == 2) msg_byte = "=";
                    else if (pos < 7'd67)
                        msg_byte = hex_nybble(resp_dump[255 - (pos - 3) * 4 -: 4]);
                    else if (pos == 67) msg_byte = 8'h0D;
                    else msg_byte = 8'h0A;
                end
                default: msg_byte = 8'h0A;
            endcase
        end
    endfunction

    function automatic [6:0] msg_len(input [3:0] which);
        begin
            case (which)
                MSG_BOOT: msg_len = 7'd5;
                MSG_FRAME: msg_len = 7'd3;
                MSG_IP: msg_len = 7'd3;
                MSG_UDP_PROTO: msg_len = 7'd3;
                MSG_PAYLOAD_START: msg_len = 7'd3;
                MSG_ARP: msg_len = 7'd4;
                MSG_UDP: msg_len = 7'd4;
                MSG_OK: msg_len = 7'd3;
                MSG_ER: msg_len = 7'd3;
                MSG_TX: msg_len = 7'd3;
                MSG_RESP: msg_len = 7'd69;
                default: msg_len = 7'd0;
            endcase
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 11'd0;
            msg <= MSG_NONE;
            idx <= 7'd0;
            waiting_ready_low <= 1'b0;
            msg_done_pending <= 1'b0;
            tx_valid <= 1'b0;
            tx_data <= 8'd0;
            resp_dump <= 256'd0;
        end else begin
            tx_valid <= 1'b0;
            if (event_boot) pending[0] <= 1'b1;
            if (event_frame) pending[1] <= 1'b1;
            if (event_ip) pending[2] <= 1'b1;
            if (event_udp_proto) pending[3] <= 1'b1;
            if (event_payload_start) pending[4] <= 1'b1;
            if (event_arp) pending[5] <= 1'b1;
            if (event_udp) pending[6] <= 1'b1;
            if (event_ok) pending[7] <= 1'b1;
            if (event_error) pending[8] <= 1'b1;
            if (event_tx) pending[9] <= 1'b1;
            if (event_resp) begin
                pending[10] <= 1'b1;
                resp_dump <= resp_data;
            end

            if (msg == MSG_NONE) begin
                idx <= 7'd0;
                waiting_ready_low <= 1'b0;
                msg_done_pending <= 1'b0;
                if (pending[0]) begin msg <= MSG_BOOT; pending[0] <= 1'b0; end
                else if (pending[1]) begin msg <= MSG_FRAME; pending[1] <= 1'b0; end
                else if (pending[2]) begin msg <= MSG_IP; pending[2] <= 1'b0; end
                else if (pending[3]) begin msg <= MSG_UDP_PROTO; pending[3] <= 1'b0; end
                else if (pending[4]) begin msg <= MSG_PAYLOAD_START; pending[4] <= 1'b0; end
                else if (pending[5]) begin msg <= MSG_ARP; pending[5] <= 1'b0; end
                else if (pending[6]) begin msg <= MSG_UDP; pending[6] <= 1'b0; end
                else if (pending[7]) begin msg <= MSG_OK; pending[7] <= 1'b0; end
                else if (pending[8]) begin msg <= MSG_ER; pending[8] <= 1'b0; end
                else if (pending[9]) begin msg <= MSG_TX; pending[9] <= 1'b0; end
                else if (pending[10]) begin msg <= MSG_RESP; pending[10] <= 1'b0; end
            end else if (waiting_ready_low) begin
                if (!tx_ready) begin
                    waiting_ready_low <= 1'b0;
                    if (msg_done_pending) begin
                        msg <= MSG_NONE;
                        idx <= 7'd0;
                        msg_done_pending <= 1'b0;
                    end
                end
            end else if (tx_ready) begin
                tx_data <= msg_byte(msg, idx);
                tx_valid <= 1'b1;
                waiting_ready_low <= 1'b1;
                if (idx == msg_len(msg) - 7'd1) begin
                    msg_done_pending <= 1'b1;
                end else begin
                    idx <= idx + 7'd1;
                end
            end
        end
    end

endmodule
