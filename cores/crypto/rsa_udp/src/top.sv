module top(
    input clk,
    input rst,

    input netrmii_clk50m,
    input netrmii_rx_crs,
    input [1:0] netrmii_rxd,
    output netrmii_mdc,
    output netrmii_txen,
    inout netrmii_mdio,
    output [1:0] netrmii_txd,
    output phyrst,
    output uart_tx_pin,

    output [5:0] led
);

    logic clk1m;
    logic clk6m;
    PLL_6M pll6m (
        .clkout(clk6m),
        .clkoutd(clk1m),
        .clkin(clk)
    );

    logic clk50m;
    logic ready;
    logic service_busy;
    logic rsa_busy;
    logic last_ok;
    logic last_error;
    logic [23:0] blink;
    logic debug_arp;
    logic debug_frame;
    logic debug_ip;
    logic debug_udp_proto;
    logic debug_payload_start;
    logic debug_udp;
    logic debug_rsa_ok;
    logic debug_rsa_error;
    logic debug_tx_udp;
    logic boot_sent;
    logic event_boot;
    logic [7:0] resp_status;
    logic [15:0] resp_cycles;
    logic [255:0] resp_ciphertext;

    rsa_udp_min_endpoint endpoint_inst (
        .clk1m(clk1m),
        .rst_n(rst),
        .netrmii_clk50m(netrmii_clk50m),
        .netrmii_rx_crs(netrmii_rx_crs),
        .netrmii_rxd(netrmii_rxd),
        .netrmii_mdc(netrmii_mdc),
        .netrmii_txen(netrmii_txen),
        .netrmii_mdio(netrmii_mdio),
        .netrmii_txd(netrmii_txd),
        .phyrst(phyrst),
        .clk50m(clk50m),
        .ready(ready),
        .service_busy(service_busy),
        .rsa_busy(rsa_busy),
        .last_ok(last_ok),
        .last_error(last_error),
        .debug_frame(debug_frame),
        .debug_ip(debug_ip),
        .debug_udp_proto(debug_udp_proto),
        .debug_payload_start(debug_payload_start),
        .debug_arp(debug_arp),
        .debug_udp(debug_udp),
        .debug_rsa_ok(debug_rsa_ok),
        .debug_rsa_error(debug_rsa_error),
        .debug_tx_udp(debug_tx_udp),
        .resp_status(resp_status),
        .resp_cycles(resp_cycles),
        .resp_ciphertext(resp_ciphertext)
    );

    always_ff @(posedge clk50m or negedge ready) begin
        if (!ready) begin
            blink <= 24'd0;
            boot_sent <= 1'b0;
            event_boot <= 1'b0;
        end else begin
            blink <= blink + 24'd1;
            event_boot <= 1'b0;
            if (!boot_sent) begin
                boot_sent <= 1'b1;
                event_boot <= 1'b1;
            end
        end
    end

    uart_event_debug debug_uart (
        .clk(clk50m),
        .rst_n(ready),
        .event_boot(event_boot),
        .event_frame(debug_frame),
        .event_ip(debug_ip),
        .event_udp_proto(debug_udp_proto),
        .event_payload_start(debug_payload_start),
        .event_arp(debug_arp),
        .event_udp(debug_udp),
        .event_ok(debug_rsa_ok),
        .event_error(debug_rsa_error),
        .event_tx(debug_tx_udp),
        .event_resp(debug_tx_udp),
        .resp_data(resp_ciphertext),
        .uart_tx_pin(uart_tx_pin)
    );

    assign led[0] = ready;
    assign led[1] = service_busy;
    assign led[2] = rsa_busy;
    assign led[3] = last_ok;
    assign led[4] = last_error;
    assign led[5] = blink[23];

endmodule
