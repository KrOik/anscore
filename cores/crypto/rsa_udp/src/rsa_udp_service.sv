module rsa_udp_service #(
    parameter integer WIDTH = 256,
    parameter integer WIDTH_BYTES = WIDTH / 8
) (
    input clk,
    input rst_n,

    input rx_head_av,
    input [31:0] rx_head,
    output reg rx_head_rdy,

    input rx_data_av,
    input [7:0] rx_data,
    output reg rx_data_rdy,

    output reg [31:0] tx_ip,
    output reg [15:0] tx_dst_port,
    output [15:0] tx_src_port,
    output reg tx_req,
    output reg [7:0] tx_data,
    output reg tx_data_av,
    input tx_req_rdy,
    input tx_data_rdy,

    output reg service_busy,
    output rsa_busy,
    output reg last_ok,
    output reg last_error
);

    localparam [15:0] REQUEST_LEN = WIDTH_BYTES + 16'd5;
    localparam [15:0] RESPONSE_LEN = WIDTH_BYTES + 16'd8;

    localparam [7:0] STATUS_OK = 8'd0;
    localparam [7:0] STATUS_BAD_MAGIC = 8'd1;
    localparam [7:0] STATUS_BAD_LEN = 8'd2;
    localparam [7:0] STATUS_RANGE = 8'd3;
    localparam [7:0] STATUS_BAD_OP = 8'd4;

    localparam [3:0] ST_IDLE = 4'd0;
    localparam [3:0] ST_HEAD0 = 4'd1;
    localparam [3:0] ST_HEAD1 = 4'd2;
    localparam [3:0] ST_HEAD2 = 4'd3;
    localparam [3:0] ST_HEAD3 = 4'd4;
    localparam [3:0] ST_PAYLOAD = 4'd5;
    localparam [3:0] ST_RSA_START = 4'd6;
    localparam [3:0] ST_RSA_WAIT = 4'd7;
    localparam [3:0] ST_TX_DATA = 4'd8;
    localparam [3:0] ST_TX_REQ = 4'd9;

    assign tx_src_port = 16'd11451;

    reg [3:0] state;
    reg [15:0] payload_len;
    reg [15:0] payload_count;
    reg [15:0] tx_count;
    reg [15:0] src_port;
    reg [7:0] response_status;
    reg [15:0] rsa_cycles;
    reg [WIDTH-1:0] message_shift;
    reg [WIDTH-1:0] ciphertext_latched;

    reg rsa_start;
    wire rsa_done;
    wire rsa_error;
    wire [15:0] rsa_cycle_count;
    wire [WIDTH-1:0] rsa_ciphertext;

    rsa_modexp #(
        .WIDTH(WIDTH)
    ) rsa_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(rsa_start),
        .message(message_shift),
        .busy(rsa_busy),
        .done(rsa_done),
        .error(rsa_error),
        .cycles(rsa_cycle_count),
        .ciphertext(rsa_ciphertext)
    );

    function automatic [7:0] response_byte;
        input [15:0] idx;
        begin
            if (idx == 16'd0) response_byte = "R";
            else if (idx == 16'd1) response_byte = "S";
            else if (idx == 16'd2) response_byte = "A";
            else if (idx == 16'd3) response_byte = "R";
            else if (idx == 16'd4) response_byte = response_status;
            else if (idx == 16'd5) response_byte = rsa_cycles[15:8];
            else if (idx == 16'd6) response_byte = rsa_cycles[7:0];
            else if (idx == 16'd7) response_byte = WIDTH_BYTES[7:0];
            else if (idx < RESPONSE_LEN)
                response_byte = ciphertext_latched[(WIDTH_BYTES - 1 - (idx - 16'd8)) * 8 +: 8];
            else response_byte = 8'h00;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            payload_len <= 16'd0;
            payload_count <= 16'd0;
            tx_count <= 16'd0;
            src_port <= 16'd0;
            tx_ip <= 32'd0;
            tx_dst_port <= 16'd0;
            response_status <= STATUS_OK;
            rsa_cycles <= 16'd0;
            message_shift <= {WIDTH{1'b0}};
            ciphertext_latched <= {WIDTH{1'b0}};
            rsa_start <= 1'b0;
            rx_head_rdy <= 1'b0;
            rx_data_rdy <= 1'b0;
            tx_req <= 1'b0;
            tx_data <= 8'd0;
            tx_data_av <= 1'b0;
            service_busy <= 1'b0;
            last_ok <= 1'b0;
            last_error <= 1'b0;
        end else begin
            rsa_start <= 1'b0;
            rx_head_rdy <= 1'b0;
            rx_data_rdy <= 1'b0;
            tx_req <= 1'b0;
            tx_data_av <= 1'b0;
            service_busy <= (state != ST_IDLE);

            case (state)
                ST_IDLE: begin
                    payload_count <= 16'd0;
                    tx_count <= 16'd0;
                    message_shift <= {WIDTH{1'b0}};
                    ciphertext_latched <= {WIDTH{1'b0}};
                    rsa_cycles <= 16'd0;
                    response_status <= STATUS_OK;
                    if (rx_head_av) begin
                        rx_head_rdy <= 1'b1;
                        tx_ip <= rx_head;
                        state <= ST_HEAD1;
                    end
                end

                ST_HEAD1: begin
                    if (rx_head_av) begin
                        rx_head_rdy <= 1'b1;
                        state <= ST_HEAD2;
                    end
                end

                ST_HEAD2: begin
                    if (rx_head_av) begin
                        rx_head_rdy <= 1'b1;
                        src_port <= rx_head[31:16];
                        tx_dst_port <= rx_head[31:16];
                        state <= ST_HEAD3;
                    end
                end

                ST_HEAD3: begin
                    if (rx_head_av) begin
                        rx_head_rdy <= 1'b1;
                        payload_len <= rx_head[15:0];
                        if (rx_head[15:0] != REQUEST_LEN) begin
                            response_status <= STATUS_BAD_LEN;
                        end
                        state <= ST_PAYLOAD;
                    end
                end

                ST_PAYLOAD: begin
                    if (payload_count == payload_len) begin
                        if (response_status != STATUS_OK) begin
                            state <= ST_TX_DATA;
                        end else begin
                            state <= ST_RSA_START;
                        end
                    end else if (rx_data_av) begin
                        rx_data_rdy <= 1'b1;

                        if (payload_count == 16'd0 && rx_data != "R") response_status <= STATUS_BAD_MAGIC;
                        if (payload_count == 16'd1 && rx_data != "S") response_status <= STATUS_BAD_MAGIC;
                        if (payload_count == 16'd2 && rx_data != "A") response_status <= STATUS_BAD_MAGIC;
                        if (payload_count == 16'd3 && rx_data != "1") response_status <= STATUS_BAD_MAGIC;
                        if (payload_count == 16'd4 && rx_data != 8'h01) response_status <= STATUS_BAD_OP;

                        if (payload_count >= 16'd5 && payload_count < REQUEST_LEN) begin
                            message_shift <= {message_shift[WIDTH-9:0], rx_data};
                        end
                        payload_count <= payload_count + 16'd1;
                    end
                end

                ST_RSA_START: begin
                    rsa_start <= 1'b1;
                    state <= ST_RSA_WAIT;
                end

                ST_RSA_WAIT: begin
                    if (rsa_done) begin
                        rsa_cycles <= rsa_cycle_count;
                        if (rsa_error) begin
                            response_status <= STATUS_RANGE;
                            ciphertext_latched <= {WIDTH{1'b0}};
                        end else begin
                            response_status <= STATUS_OK;
                            ciphertext_latched <= rsa_ciphertext;
                        end
                        state <= ST_TX_DATA;
                    end
                end

                ST_TX_DATA: begin
                    if (tx_count < RESPONSE_LEN) begin
                        if (tx_data_rdy) begin
                            tx_data <= response_byte(tx_count);
                            tx_data_av <= 1'b1;
                            tx_count <= tx_count + 16'd1;
                        end
                    end else begin
                        state <= ST_TX_REQ;
                    end
                end

                ST_TX_REQ: begin
                    if (tx_req_rdy) begin
                        tx_req <= 1'b1;
                        last_ok <= (response_status == STATUS_OK);
                        last_error <= (response_status != STATUS_OK);
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    response_status <= STATUS_BAD_OP;
                    state <= ST_TX_DATA;
                end
            endcase
        end
    end

endmodule
