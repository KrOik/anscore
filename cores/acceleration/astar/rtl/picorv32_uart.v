// Small polled 16550-compatible UART subset for the PicoRV32 SoC.
//
// The native-bus adapter presents byte offsets in addr.  The register map
// deliberately matches fw/regs.h:
//
//   0x00 THR write / RBR read / DLL with DLAB
//   0x04 IER       / DLM with DLAB
//   0x08 FCR write / IIR read
//   0x0c LCR
//   0x10 MCR
//   0x14 LSR
//   0x1c SCR
//
// This SoC's shipped firmware uses the UART as a polled console transmitter.
// Its simple MMIO interface intentionally has no read-valid signal, so RBR is
// kept inactive: it reads as zero and LSR[0] remains clear.  The rx port is
// retained for board-level compatibility; receive support can be added later
// only together with an unambiguous read-acknowledge contract.
//
// DIVISOR is the number of clocks per bit minus one.  The reset value of 233
// therefore implements 27 MHz / 115200 baud (234 clocks per serial bit).
`timescale 1ns/1ps

module picorv32_uart #(
    parameter [15:0] DEFAULT_DIVISOR = 16'd233
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr_en,
    input  wire [4:0]  addr,   // byte offset
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        rx,
    output wire        tx
);

    localparam [2:0] R_RBR_THR_DLL = 3'd0,
                     R_IER_DLM     = 3'd1,
                     R_IIR_FCR     = 3'd2,
                     R_LCR         = 3'd3,
                     R_MCR         = 3'd4,
                     R_LSR         = 3'd5,
                     R_MSR         = 3'd6,
                     R_SCR         = 3'd7;

    wire [2:0] reg_addr = addr[4:2];

    reg [7:0] dll;
    reg [7:0] dlm;
    reg [7:0] ier;
    reg [7:0] lcr;
    reg [7:0] mcr;
    reg [7:0] scr;

    // One byte of holding storage is enough for the polling contract.  THRE
    // reports this storage, while TEMT additionally waits for the shifter.
    reg [7:0] tx_holding;
    reg       tx_holding_valid;
    reg [9:0] tx_shift;       // {stop, data[7:0], start}; bit 0 is on tx
    reg       tx_busy;
    reg [3:0] tx_bit_count;   // start=0, data=1..8, stop=9
    reg [15:0] tx_baud_count;

    wire [15:0] divisor = {dlm, dll};
    wire        tx_thre = ~tx_holding_valid;
    wire        tx_temt = ~tx_holding_valid & ~tx_busy;
    wire [7:0]  lsr_value = {1'b0, tx_temt, tx_thre, 3'b000, 2'b00};

    // Keep an otherwise unused board input visible in the module interface.
    // See the receive note at the top of this file.
    wire unused_rx = rx;

    assign tx = tx_busy ? tx_shift[0] : 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dll              <= DEFAULT_DIVISOR[7:0];
            dlm              <= DEFAULT_DIVISOR[15:8];
            ier              <= 8'd0;
            lcr              <= 8'h03;  // 8 data bits, one stop, no parity
            mcr              <= 8'd0;
            scr              <= 8'd0;
            tx_holding       <= 8'd0;
            tx_holding_valid <= 1'b0;
            tx_shift         <= 10'h3ff;
            tx_busy          <= 1'b0;
            tx_bit_count     <= 4'd0;
            tx_baud_count    <= 16'd0;
        end else begin
            // Serialiser.  Each element of tx_shift remains on the pin for
            // divisor + 1 clocks.  A zero divisor is well-defined as one
            // clock per bit, which is useful for fast simulation.
            if (tx_busy) begin
                if (tx_baud_count == divisor) begin
                    tx_baud_count <= 16'd0;
                    if (tx_bit_count == 4'd9) begin
                        tx_busy      <= 1'b0;
                        tx_bit_count <= 4'd0;
                        tx_shift     <= 10'h3ff;
                    end else begin
                        tx_shift     <= {1'b1, tx_shift[9:1]};
                        tx_bit_count <= tx_bit_count + 4'd1;
                    end
                end else begin
                    tx_baud_count <= tx_baud_count + 16'd1;
                end
            end else if (tx_holding_valid) begin
                tx_shift         <= {1'b1, tx_holding, 1'b0};
                tx_busy          <= 1'b1;
                tx_bit_count     <= 4'd0;
                tx_baud_count    <= 16'd0;
                tx_holding_valid <= 1'b0;
            end

            if (wr_en) begin
                case (reg_addr)
                    R_RBR_THR_DLL: begin
                        if (lcr[7]) begin
                            dll <= wdata[7:0];
                        end else if (!tx_holding_valid || !tx_busy) begin
                            // When an idle shifter consumes the old holding
                            // byte on this edge, accepting a replacement here
                            // preserves a one-byte transmit queue.
                            tx_holding       <= wdata[7:0];
                            tx_holding_valid <= 1'b1;
                        end
                    end

                    R_IER_DLM: begin
                        if (lcr[7])
                            dlm <= wdata[7:0];
                        else
                            ier <= wdata[7:0];
                    end

                    R_IIR_FCR: begin
                        // FCR is write-only in this subset.  Bit 1 clears an
                        // inactive receive path.  Bit 2 discards both the
                        // holding byte and any byte currently being shifted.
                        if (wdata[2]) begin
                            tx_holding_valid <= 1'b0;
                            tx_shift         <= 10'h3ff;
                            tx_busy          <= 1'b0;
                            tx_bit_count     <= 4'd0;
                            tx_baud_count    <= 16'd0;
                        end
                    end

                    R_LCR: lcr <= wdata[7:0];
                    R_MCR: mcr <= wdata[7:0];
                    R_SCR: scr <= wdata[7:0];
                    default: ;
                endcase
            end
        end
    end

    // The PicoRV32 adapter samples rdata combinationally.  IIR[0] is one
    // because this intentionally interrupt-free peripheral never asserts a
    // pending interrupt.
    always @(*) begin
        rdata = 32'd0;
        case (reg_addr)
            R_RBR_THR_DLL: rdata = lcr[7] ? {24'd0, dll} : 32'd0;
            R_IER_DLM:     rdata = lcr[7] ? {24'd0, dlm} : {24'd0, ier};
            R_IIR_FCR:     rdata = {24'd0, 8'h01};
            R_LCR:         rdata = {24'd0, lcr};
            R_MCR:         rdata = {24'd0, mcr};
            R_LSR:         rdata = {24'd0, lsr_value};
            R_MSR:         rdata = 32'd0;
            R_SCR:         rdata = {24'd0, scr};
            default:       rdata = 32'd0;
        endcase
    end

endmodule
