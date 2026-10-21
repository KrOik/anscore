`timescale 1ns/1ps

module tb_rsa_udp_service;
    localparam [15:0] REQ_LEN = 16'd37;
    localparam [15:0] RESP_LEN = 16'd40;
    localparam [255:0] MSG =
        256'h123456789ABCDEF00112233445566778899AABBCCDDEEFF00123456789ABCDEF;
    localparam [255:0] EXPECTED =
        256'hAEB8EDC48106703EE89EE3E6B9820CCAEB46B14A8768AB29D69519F296C2945A;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg rx_head_av = 1'b0;
    reg [31:0] rx_head = 32'd0;
    wire rx_head_rdy;
    reg rx_data_av = 1'b0;
    reg [7:0] rx_data = 8'd0;
    wire rx_data_rdy;

    wire [31:0] tx_ip;
    wire [15:0] tx_dst_port;
    wire [15:0] tx_src_port;
    wire tx_req;
    wire [7:0] tx_data;
    wire tx_data_av;
    reg tx_req_rdy = 1'b1;
    reg tx_data_rdy = 1'b1;

    wire service_busy;
    wire rsa_busy;
    wire last_ok;
    wire last_error;

    reg [7:0] tx_buf [0:63];
    integer tx_len = 0;
    integer i;
    reg [255:0] got_cipher;

    rsa_udp_service dut (
        .clk(clk),
        .rst_n(rst_n),
        .rx_head_av(rx_head_av),
        .rx_head(rx_head),
        .rx_head_rdy(rx_head_rdy),
        .rx_data_av(rx_data_av),
        .rx_data(rx_data),
        .rx_data_rdy(rx_data_rdy),
        .tx_ip(tx_ip),
        .tx_dst_port(tx_dst_port),
        .tx_src_port(tx_src_port),
        .tx_req(tx_req),
        .tx_data(tx_data),
        .tx_data_av(tx_data_av),
        .tx_req_rdy(tx_req_rdy),
        .tx_data_rdy(tx_data_rdy),
        .service_busy(service_busy),
        .rsa_busy(rsa_busy),
        .last_ok(last_ok),
        .last_error(last_error)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (tx_data_av) begin
            tx_buf[tx_len] <= tx_data;
            tx_len <= tx_len + 1;
        end
    end

    task pulse_head;
        input [31:0] word;
        begin
            @(negedge clk);
            rx_head = word;
            rx_head_av = 1'b1;
            @(negedge clk);
            rx_head_av = 1'b0;
            rx_head = 32'd0;
            repeat (1) @(negedge clk);
        end
    endtask

    task pulse_data;
        input [7:0] byte_value;
        begin
            @(negedge clk);
            rx_data = byte_value;
            rx_data_av = 1'b1;
            @(negedge clk);
            rx_data_av = 1'b0;
            rx_data = 8'd0;
            repeat (1) @(negedge clk);
        end
    endtask

    task send_request;
        begin
            pulse_head({8'd192, 8'd168, 8'd15, 8'd15});
            pulse_head({8'd192, 8'd168, 8'd15, 8'd14});
            pulse_head({16'd5000, 16'd11451});
            pulse_head({16'h1234, REQ_LEN});

            pulse_data("R");
            pulse_data("S");
            pulse_data("A");
            pulse_data("1");
            pulse_data(8'h01);
            for (i = 31; i >= 0; i = i - 1) begin
                pulse_data(MSG[i*8 +: 8]);
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        send_request();

        for (i = 0; i < 10000 && !tx_req; i = i + 1) begin
            @(posedge clk);
        end
        if (!tx_req) begin
            $display("FAIL timeout waiting for tx_req");
            $finish;
        end

        @(posedge clk);
        if (tx_len != RESP_LEN) begin
            $display("FAIL response length got=%0d expected=%0d", tx_len, RESP_LEN);
            $finish;
        end
        if (tx_ip !== {8'd192, 8'd168, 8'd15, 8'd15}) begin
            $display("FAIL tx_ip %08x", tx_ip);
            $finish;
        end
        if (tx_dst_port !== 16'd5000 || tx_src_port !== 16'd11451) begin
            $display("FAIL ports src=%0d dst=%0d", tx_src_port, tx_dst_port);
            $finish;
        end
        if (tx_buf[0] !== "R" || tx_buf[1] !== "S" || tx_buf[2] !== "A" || tx_buf[3] !== "R") begin
            $display("FAIL response magic");
            $finish;
        end
        if (tx_buf[4] !== 8'd0 || tx_buf[7] !== 8'd32) begin
            $display("FAIL response status=%0d width=%0d", tx_buf[4], tx_buf[7]);
            $finish;
        end

        got_cipher = 256'd0;
        for (i = 0; i < 32; i = i + 1) begin
            got_cipher = {got_cipher[247:0], tx_buf[8+i]};
        end
        if (got_cipher !== EXPECTED) begin
            $display("FAIL cipher got=%064x expected=%064x", got_cipher, EXPECTED);
            $finish;
        end

        $display("RSA UDP SERVICE PASS cycles=%0d cipher=%064x",
                 {tx_buf[5], tx_buf[6]}, got_cipher);
        $finish;
    end

endmodule
