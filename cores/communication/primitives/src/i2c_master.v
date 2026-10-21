// I2C master: 7-bit addressing, single/multi-byte write and read, ACK/NACK
// handling, clock-stretch tolerant, open-drain SDA/SCL via _oe outputs
// (oe=1 drives the line low; external pull-ups provide the high level).
//
// Transaction interface (level handshakes, safe for slow consumers):
//   start (pulse) + addr + rw + len  ->  frames one transaction
//   write path: tx_ready/tx_valid/tx_data  per-byte stream
//   read  path: rx_valid/rx_ack/rx_data    per-byte stream
//   done (level, held until next start); nack = any NACK seen this txn
//
// QDIV = clk_en ticks per quarter SCL period. All state is clk_en gated.
module i2c_master #(
    parameter integer QDIV = 64
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clk_en,
    input  wire       start,
    input  wire [6:0] addr,
    input  wire       rw,        // 0 = write, 1 = read
    input  wire [4:0] len,       // data byte count, 1..16
    input  wire [7:0] tx_data,
    input  wire       tx_valid,
    output reg        tx_ready,
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    input  wire       rx_ack,
    output reg        busy,
    output reg        done,
    output reg        nack,
    input  wire       sda_in,
    input  wire       scl_in,
    output reg        sda_oe,
    output reg        scl_oe
);

localparam integer QW = (QDIV <= 1) ? 1 : $clog2(QDIV);

localparam [4:0]
    S_IDLE = 5'd0,
    S_STA0 = 5'd1,    // bus free: sda/scl released, wait scl high
    S_STA1 = 5'd2,    // sda falls while scl high (START)
    S_STA2 = 5'd3,    // scl falls
    S_W0   = 5'd4,    // scl low: set sda for outgoing bit
    S_W1   = 5'd5,    // release scl, wait scl_in high (stretch window)
    S_W2   = 5'd6,    // scl high hold
    S_W3   = 5'd7,    // scl falls, bit dispatch
    S_R0   = 5'd8,    // scl low: release sda
    S_R1   = 5'd9,    // release scl, wait high
    S_R2   = 5'd10,   // sample sda
    S_R3   = 5'd11,   // scl falls, bit dispatch
    S_GETB = 5'd12,   // fetch next write byte
    S_PUTB = 5'd13,   // deliver read byte
    S_STO0 = 5'd14,   // sda low, scl low
    S_STO1 = 5'd15,   // release scl, wait high
    S_STO2 = 5'd16,   // release sda (rises while scl high = STOP)
    S_DONE = 5'd17;

localparam [2:0]
    CTX_ADDR  = 3'd0,   // W-seq: sending {addr,rw}
    CTX_WACK  = 3'd1,   // R-seq: reading slave ACK bit
    CTX_WDATA = 3'd2,   // W-seq: sending data byte
    CTX_RDATA = 3'd3,   // R-seq: receiving data byte
    CTX_MACK  = 3'd4;   // W-seq: sending master ACK/NACK bit

reg [4:0]    state;
reg [2:0]    ctx;
reg          ack_after;   // 0 = ack follows addr, 1 = ack follows wdata
reg [QW-1:0] qcnt;
reg [3:0]    bit_cnt;
reg [4:0]    byte_cnt;
reg [4:0]    len_r;
reg          rw_r;
reg [7:0]    shift;
reg          sda_meta, sda_s;
reg          scl_meta, scl_s;

wire last_byte = (byte_cnt == len_r - 5'd1);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= S_IDLE;
        ctx       <= CTX_ADDR;
        ack_after <= 1'b0;
        qcnt      <= {QW{1'b0}};
        bit_cnt   <= 4'd0;
        byte_cnt  <= 5'd0;
        len_r     <= 5'd0;
        rw_r      <= 1'b0;
        shift     <= 8'd0;
        sda_meta  <= 1'b1; sda_s <= 1'b1;
        scl_meta  <= 1'b1; scl_s <= 1'b1;
        sda_oe    <= 1'b0; scl_oe <= 1'b0;
        tx_ready  <= 1'b0;
        rx_data   <= 8'd0; rx_valid <= 1'b0;
        busy      <= 1'b0; done <= 1'b0; nack <= 1'b0;
    end else if (clk_en) begin
        sda_meta <= sda_in; sda_s <= sda_meta;
        scl_meta <= scl_in; scl_s <= scl_meta;

        case (state)
            // -------------------------------------------------- idle / start
            S_IDLE: begin
                sda_oe <= 1'b0; scl_oe <= 1'b0;
                busy   <= 1'b0;
                qcnt   <= {QW{1'b0}};
                if (start) begin
                    busy     <= 1'b1;
                    done     <= 1'b0;
                    nack     <= 1'b0;
                    rw_r     <= rw;
                    len_r    <= len;
                    byte_cnt <= 5'd0;
                    bit_cnt  <= 4'd0;
                    shift    <= {addr, rw};
                    ctx      <= CTX_ADDR;
                    state    <= S_STA0;
                end
            end

            S_STA0: begin
                sda_oe <= 1'b0; scl_oe <= 1'b0;
                if (scl_s && sda_s) begin
                    if (qcnt == QDIV - 1) begin
                        qcnt   <= {QW{1'b0}};
                        state  <= S_STA1;
                    end else qcnt <= qcnt + 1'b1;
                end else qcnt <= {QW{1'b0}};
            end

            S_STA1: begin                        // sda falls while scl high
                sda_oe <= 1'b1;
                if (qcnt == QDIV - 1) begin
                    qcnt  <= {QW{1'b0}};
                    state <= S_STA2;
                end else qcnt <= qcnt + 1'b1;
            end

            S_STA2: begin                        // scl falls -> first bit
                scl_oe <= 1'b1;
                if (qcnt == QDIV - 1) begin
                    qcnt  <= {QW{1'b0}};
                    state <= S_W0;
                end else qcnt <= qcnt + 1'b1;
            end

            // -------------------------------------------------- write a bit
            S_W0: begin                          // scl low: drive bit value
                sda_oe <= ~shift[7];
                scl_oe <= 1'b1;
                if (qcnt == QDIV - 1) begin
                    qcnt  <= {QW{1'b0}};
                    state <= S_W1;
                end else qcnt <= qcnt + 1'b1;
            end

            S_W1: begin                          // release scl, wait high
                scl_oe <= 1'b0;
                if (scl_s) begin
                    if (qcnt == QDIV - 1) begin
                        qcnt  <= {QW{1'b0}};
                        state <= S_W2;
                    end else qcnt <= qcnt + 1'b1;
                end else qcnt <= {QW{1'b0}};     // slave stretching
            end

            S_W2: begin                          // scl high hold
                if (qcnt == QDIV - 1) begin
                    qcnt  <= {QW{1'b0}};
                    state <= S_W3;
                end else qcnt <= qcnt + 1'b1;
            end

            S_W3: begin                          // scl falls, bit done
                scl_oe <= 1'b1;
                if (qcnt == QDIV - 1) begin
                    shift <= {shift[6:0], 1'b0};
                    qcnt <= {QW{1'b0}};
                    if (bit_cnt == 4'd7) begin
                        bit_cnt <= 4'd0;
                        case (ctx)
                            CTX_ADDR: begin      // addr sent -> read ack
                                ctx       <= CTX_WACK;
                                ack_after <= 1'b0;
                                bit_cnt   <= 4'd7; // single-bit sequence
                                state     <= S_R0;
                            end
                            CTX_WDATA: begin     // byte sent -> read ack
                                ctx       <= CTX_WACK;
                                ack_after <= 1'b1;
                                bit_cnt   <= 4'd7;
                                state     <= S_R0;
                            end
                            CTX_MACK: begin      // master ack/nack sent
                                if (last_byte) begin
                                    state <= S_STO0;
                                end else begin
                                    byte_cnt <= byte_cnt + 5'd1;
                                    ctx      <= CTX_RDATA;
                                    state    <= S_R0;
                                end
                            end
                            default: state <= S_STO0;
                        endcase
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                        state   <= S_W0;
                    end
                end else qcnt <= qcnt + 1'b1;
            end

            // -------------------------------------------------- read a bit
            S_R0: begin                          // scl low: release sda
                sda_oe <= 1'b0;
                scl_oe <= 1'b1;
                if (qcnt == QDIV - 1) begin
                    qcnt  <= {QW{1'b0}};
                    state <= S_R1;
                end else qcnt <= qcnt + 1'b1;
            end

            S_R1: begin                          // release scl, wait high
                scl_oe <= 1'b0;
                if (scl_s) begin
                    if (qcnt == QDIV - 1) begin
                        qcnt  <= {QW{1'b0}};
                        state <= S_R2;
                    end else qcnt <= qcnt + 1'b1;
                end else qcnt <= {QW{1'b0}};     // slave stretching
            end

            S_R2: begin                          // sample sda mid-high
                if (qcnt == QDIV - 1) begin
                    shift <= {shift[6:0], sda_s};
                    qcnt  <= {QW{1'b0}};
                    state <= S_R3;
                end else qcnt <= qcnt + 1'b1;
            end

            S_R3: begin                          // scl falls, bit done
                scl_oe <= 1'b1;
                if (qcnt == QDIV - 1) begin
                    qcnt <= {QW{1'b0}};
                    if (bit_cnt == 4'd7) begin
                        bit_cnt <= 4'd0;
                        case (ctx)
                            CTX_WACK: begin      // ack bit is in shift[0]
                                if (shift[0]) begin
                                    nack  <= 1'b1;
                                    state <= S_STO0;
                                end else if (!ack_after) begin
                                    // addr acked: branch on rw
                                    if (rw_r) begin
                                        ctx     <= CTX_RDATA;
                                        state   <= S_R0;
                                    end else begin
                                        state   <= S_GETB;
                                    end
                                end else begin
                                    // data byte acked
                                    if (last_byte) begin
                                        state <= S_STO0;
                                    end else begin
                                        byte_cnt <= byte_cnt + 5'd1;
                                        state    <= S_GETB;
                                    end
                                end
                            end
                            CTX_RDATA: begin     // byte received -> deliver
                                rx_data  <= shift;
                                rx_valid <= 1'b1;
                                state    <= S_PUTB;
                            end
                            default: state <= S_STO0;
                        endcase
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                        state   <= S_R0;
                    end
                end else qcnt <= qcnt + 1'b1;
            end

            // -------------------------------------------------- byte streams
            S_GETB: begin
                tx_ready <= 1'b1;
                if (tx_valid) begin
                    tx_ready <= 1'b0;
                    shift    <= tx_data;
                    ctx      <= CTX_WDATA;
                    bit_cnt  <= 4'd0;
                    state    <= S_W0;
                end
            end

            S_PUTB: begin
                if (rx_ack) begin
                    rx_valid <= 1'b0;
                    // master ack bit: 0 = more bytes, 1 = nack on last
                    shift   <= {last_byte, 7'd0};
                    ctx     <= CTX_MACK;
                    bit_cnt <= 4'd7;           // single-bit sequence
                    state   <= S_W0;
                end
            end

            // -------------------------------------------------- stop / done
            S_STO0: begin                        // sda low while scl low
                sda_oe <= 1'b1;
                scl_oe <= 1'b1;
                if (qcnt == QDIV - 1) begin
                    qcnt  <= {QW{1'b0}};
                    state <= S_STO1;
                end else qcnt <= qcnt + 1'b1;
            end

            S_STO1: begin                        // release scl, wait high
                scl_oe <= 1'b0;
                if (scl_s) begin
                    if (qcnt == QDIV - 1) begin
                        qcnt  <= {QW{1'b0}};
                        state <= S_STO2;
                    end else qcnt <= qcnt + 1'b1;
                end else qcnt <= {QW{1'b0}};
            end

            S_STO2: begin                        // sda rises while scl high
                sda_oe <= 1'b0;
                if (qcnt == QDIV - 1) begin
                    qcnt  <= {QW{1'b0}};
                    state <= S_DONE;
                end else qcnt <= qcnt + 1'b1;
            end

            S_DONE: begin
                done  <= 1'b1;
                busy  <= 1'b0;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
