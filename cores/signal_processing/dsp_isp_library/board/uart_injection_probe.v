// Transport probe only, not an algorithm acceptance harness.
// Echo external bytes XOR A5, allowing host nonce verification over LA D0.
module uart_injection_probe(input wire clk, uart_rx_pin,
                            output wire uart_tx, dbg_uart);
    reg [12:0] por=0;
    always @(posedge clk) if(!por[12]) por<=por+1'b1;
    wire rst_n=por[12];
    wire [7:0] data;
    wire valid, framing_error, ready;
    reg pending;
    reg [7:0] response;
    wire ack=valid && (!pending || ready);
    uart_rx rx(.clk(clk),.rst_n(rst_n),.clk_en(1'b1),.rx_pin(uart_rx_pin),
      .rx_data(data),.rx_valid(valid),.rx_ack(ack),.framing_err(framing_error));
    always @(posedge clk) begin
        if(!rst_n) pending<=0;
        else begin
            if(ready) pending<=0;
            if(ack && !framing_error) begin pending<=1;response<=data^8'ha5;end
        end
    end
    uart_tx tx(.clk(clk),.rst_n(rst_n),.tx_data(response),.tx_data_valid(pending),
      .tx_data_ready(ready),.tx_pin(uart_tx),.tx_busy());
    assign dbg_uart=uart_tx;
endmodule
