`default_nettype none
// Full-duplex 8N1, single-entry RX mailbox, independent TX/RX engines.
module common_uart #(
    parameter integer CLOCK_HZ=27000000, parameter integer BAUD=115200
) (
    input wire clk, rst_n, clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire cmd_write, input wire [7:0] cmd_addr, input wire [31:0] cmd_wdata,
    output reg rsp_valid, input wire rsp_ready,
    output reg [31:0] rsp_rdata, output reg [1:0] rsp_error,
    input wire uart_rx, output reg uart_tx
);
    localparam integer RESET_DIV=(BAUD>0 && CLOCK_HZ/BAUD>=4)?CLOCK_HZ/BAUD:4;
    reg [31:0] divisor, tx_timer, rx_timer;
    reg [9:0] tx_shift;
    reg [3:0] tx_bit, rx_bit;
    reg tx_busy, rx_busy, rx_sync1, rx_sync2;
    reg [7:0] rx_shift, rx_mailbox;
    reg rx_valid, overflow, framing;
    wire take=clk_en && cmd_valid && cmd_ready;
    wire take_rx=take && !cmd_write && cmd_addr==8'h04;
    assign cmd_ready=!rsp_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divisor<=RESET_DIV; tx_timer<=0; rx_timer<=0; tx_shift<=10'h3ff;
            tx_bit<=0; rx_bit<=0; tx_busy<=0; rx_busy<=0;
            rx_sync1<=1; rx_sync2<=1; rx_shift<=0; rx_mailbox<=0;
            rx_valid<=0; overflow<=0; framing<=0; uart_tx<=1;
            rsp_valid<=0; rsp_rdata<=0; rsp_error<=0;
        end else begin
            rx_sync1<=uart_rx; rx_sync2<=rx_sync1;
            if (clk_en && rsp_valid && rsp_ready) rsp_valid<=0;
            if (take) begin
                rsp_valid<=1; rsp_rdata<=0; rsp_error<=0;
                case (cmd_addr)
                    8'h00: if (!cmd_write) rsp_error<=2;
                        else if (tx_busy || cmd_wdata[31:8]!=0) rsp_error<=3;
                        else begin
                            tx_shift<={1'b1,cmd_wdata[7:0],1'b0}; tx_bit<=0;
                            tx_busy<=1; uart_tx<=0; tx_timer<=divisor-1;
                        end
                    8'h04: if (cmd_write) rsp_error<=2;
                        else if (!rx_valid) rsp_error<=3;
                        else begin rsp_rdata<={24'b0,rx_mailbox}; rx_valid<=0; end
                    8'h08: if (cmd_write) begin
                            if ((cmd_wdata & 32'hfffffff3)!=0) rsp_error<=3;
                            else begin
                                if (cmd_wdata[2]) overflow<=0;
                                if (cmd_wdata[3]) framing<=0;
                            end
                        end else rsp_rdata<={27'b0,rx_busy,framing,overflow,rx_valid,tx_busy};
                    8'h0c: if (!cmd_write) rsp_rdata<=divisor;
                        else if (cmd_wdata<4 || tx_busy || rx_busy) rsp_error<=3;
                        else divisor<=cmd_wdata;
                    default: rsp_error<=1;
                endcase
            end
            if (tx_busy) begin
                if (tx_timer!=0) tx_timer<=tx_timer-1;
                else if (tx_bit==9) begin tx_busy<=0; uart_tx<=1; end
                else begin
                    tx_shift<={1'b1,tx_shift[9:1]}; uart_tx<=tx_shift[1];
                    tx_bit<=tx_bit+1; tx_timer<=divisor-1;
                end
            end
            if (!rx_busy) begin
                if (!rx_sync2) begin
                    rx_busy<=1; rx_bit<=0; rx_timer<=(divisor>>1)-1;
                end
            end else if (rx_timer!=0) rx_timer<=rx_timer-1;
            else begin
                rx_timer<=divisor-1;
                if (rx_bit==0) begin
                    if (rx_sync2) rx_busy<=0;
                    else rx_bit<=1;
                end else if (rx_bit<=8) begin
                    rx_shift[rx_bit-1]<=rx_sync2; rx_bit<=rx_bit+1;
                end else begin
                    rx_busy<=0;
                    if (!rx_sync2) framing<=1;
                    else if (rx_valid && !take_rx) overflow<=1;
                    else begin rx_mailbox<=rx_shift; rx_valid<=1; end
                end
            end
        end
    end
endmodule
`default_nettype wire

