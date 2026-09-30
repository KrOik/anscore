`timescale 1ns/1ps

module tb_rsa_modexp;
    localparam [255:0] MODULUS =
        256'hB7F4820717DF346B5EF24C7D132DE33AA96A477B3EDD40ACE2A4A982C4BE1EC7;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg [255:0] message = 256'd0;
    wire busy;
    wire done;
    wire error;
    wire [15:0] cycles;
    wire [255:0] ciphertext;

    rsa_modexp dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .message(message),
        .busy(busy),
        .done(done),
        .error(error),
        .cycles(cycles),
        .ciphertext(ciphertext)
    );

    always #5 clk = ~clk;

    task run_case;
        input [255:0] msg;
        input [255:0] expected;
        input expected_error;
        integer timeout;
        begin
            @(negedge clk);
            message = msg;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            timeout = 0;
            while (!done && timeout < 10000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if (!done) begin
                $display("FAIL timeout msg=%064x", msg);
                $finish;
            end
            if (error !== expected_error) begin
                $display("FAIL error msg=%064x got=%0d expected=%0d", msg, error, expected_error);
                $finish;
            end
            if (!expected_error && ciphertext !== expected) begin
                $display("FAIL cipher msg=%064x got=%064x expected=%064x", msg, ciphertext, expected);
                $finish;
            end
            $display("case msg=%064x err=%0d cycles=%0d cipher=%064x",
                     msg, error, cycles, ciphertext);
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        run_case(
            256'h0000000000000000000000000000000000000000000000000000000000000002,
            256'h1AC676FD4EA57559C783E64A7BEC34A0F10FAEBCE7799AF27BDAF8BD474B9BCC,
            1'b0
        );
        run_case(
            256'h123456789ABCDEF00112233445566778899AABBCCDDEEFF00123456789ABCDEF,
            256'hAEB8EDC48106703EE89EE3E6B9820CCAEB46B14A8768AB29D69519F296C2945A,
            1'b0
        );
        run_case(MODULUS, 256'd0, 1'b1);

        $display("RSA MODEXP PASS");
        $finish;
    end

endmodule
