// ---------------------------------------------------------------------------
// gw2a_ips_modbus_rtu_fsm : packaged, licensable wrapper for the ips_modbus_rtu_fsm core.
// Family iface.  Modbus RTU slave framing over a byte pipe: 3.5T silence detect, address filter, CRC16 check, exception responses
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_modbus_rtu_fsm #(
    parameter T35 = 40,
    parameter MIN_LEN = 4,
    parameter FUNC_LEN = 8,
    parameter FUNC_READ = 8'h03,
    parameter FUNC_WRITE = 8'h06,
    parameter EXC_FUNC = 8'h01,
    parameter CRC_POLY = 16'hA001,
    parameter CRC_SEED = 16'hFFFF
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire tick,
    input wire rx_valid,
    input wire [7:0] rx_byte,
    input wire [7:0] slv_addr,
    output wire [7:0] rx_addr,
    output wire [7:0] rx_func,
    output wire [7:0] rx_len,
    output wire [15:0] crc_state,
    output wire [7:0] silence,
    output wire [2:0] state,
    output wire tx_valid,
    output wire [7:0] tx_byte,
    output wire [2:0] tx_idx,
    output wire [7:0] crc_err_count,
    output wire [7:0] short_count,
    output wire [7:0] not_addr_count,
    output wire [7:0] broadcast_count,
    output wire [7:0] exc_count,
    output wire [7:0] frame_count
);

    ips_modbus_rtu_fsm #(
        .T35(T35),
        .MIN_LEN(MIN_LEN),
        .FUNC_LEN(FUNC_LEN),
        .FUNC_READ(FUNC_READ),
        .FUNC_WRITE(FUNC_WRITE),
        .EXC_FUNC(EXC_FUNC),
        .CRC_POLY(CRC_POLY),
        .CRC_SEED(CRC_SEED)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .tick(tick),
        .rx_valid(rx_valid),
        .rx_byte(rx_byte),
        .slv_addr(slv_addr),
        .rx_addr(rx_addr),
        .rx_func(rx_func),
        .rx_len(rx_len),
        .crc_state(crc_state),
        .silence(silence),
        .state(state),
        .tx_valid(tx_valid),
        .tx_byte(tx_byte),
        .tx_idx(tx_idx),
        .crc_err_count(crc_err_count),
        .short_count(short_count),
        .not_addr_count(not_addr_count),
        .broadcast_count(broadcast_count),
        .exc_count(exc_count),
        .frame_count(frame_count)
    );

endmodule
