// I2C slave model for selftest loopback (test fixture, also synthesizable).
// clk-sampled SDA/SCL edge detection; open-drain drive via sda_oe/scl_oe.
//   - fixed 7-bit address ADDR
//   - write: captures up to 16 bytes into cbuf, ACKs each
//   - read: emits pattern bytes  r(k) = k*41 + 0x17 (mod 256)
//   - clock stretch: when stretch_en and the ACKed write-byte index equals
//     STRETCH_BYTE, holds scl_oe low for STRETCH_TICKS after the ACK bit
// Observability: cap_sel picks a captured byte on cap_byte; byte_cnt is the
// number of bytes captured during the current/last matched write txn.
module i2c_slave_model #(
    parameter [6:0]  ADDR          = 7'h42,
    parameter [3:0]  STRETCH_BYTE  = 4'd1,
    parameter [15:0] STRETCH_TICKS = 16'd2000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       stretch_en,
    input  wire       sda_in,
    input  wire       scl_in,
    output reg        sda_oe,
    output reg        scl_oe,
    input  wire [3:0] cap_sel,
    output wire [7:0] cap_byte,
    output reg  [4:0] byte_cnt,
    output reg        addr_seen     // pulses for one clk on addr match
);

localparam [3:0]
    S_IDLE   = 4'd0,
    S_ADDR   = 4'd1,    // receiving 8 addr+r/w bits
    S_AACK0  = 4'd2,    // scl low after 8th bit: drive ack
    S_AACK1  = 4'd3,    // scl high of ack bit
    S_AACK2  = 4'd4,    // scl falls: release sda, branch
    S_WD     = 4'd5,    // write: receive data byte
    S_WACK0  = 4'd6,    // drive ack
    S_WACK1  = 4'd7,    // ack high phase
    S_WACK2  = 4'd8,    // ack done, maybe stretch
    S_STRET  = 4'd9,    // holding scl low
    S_RD     = 4'd10,   // read: driving data bits
    S_RDH    = 4'd11,   // read: bit on the wire, wait scl fall
    S_RACK   = 4'd12,   // read: sample master ack bit
    S_RACK2  = 4'd13;   // wait scl fall after master ack

reg [3:0]  state;
reg [3:0]  bit_cnt;
reg [7:0]  shift;
reg        rw_bit;
reg [7:0]  cbuf [0:15];
reg [15:0] stretch_cnt;
reg        scl_d, sda_d;
reg        scl_s, sda_s;

assign cap_byte = cbuf[cap_sel];

wire scl_rise =  scl_s && !scl_d;
wire scl_fall = !scl_s &&  scl_d;
wire sda_rise =  sda_s && !sda_d;
wire sda_fall = !sda_s &&  sda_d;
wire i2c_start = sda_fall && scl_s;
wire i2c_stop  = sda_rise && scl_s;

// read pattern byte for index k: k*41 + 0x17 = k + (k<<3) + (k<<5) + 0x17
wire [7:0] rd_pat = byte_cnt[3:0] + ({4'd0, byte_cnt[3:0]} << 3) +
                    ({4'd0, byte_cnt[3:0]} << 5) + 8'h17;
wire [4:0] byte_cnt_p1 = byte_cnt + 5'd1;
wire [7:0] rd_pat_next = byte_cnt_p1[3:0] + ({4'd0, byte_cnt_p1[3:0]} << 3) +
                         ({4'd0, byte_cnt_p1[3:0]} << 5) + 8'h17;

integer bi;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= S_IDLE;
        bit_cnt     <= 4'd0;
        shift       <= 8'd0;
        rw_bit      <= 1'b0;
        byte_cnt    <= 5'd0;
        stretch_cnt <= 16'd0;
        scl_d <= 1'b1; sda_d <= 1'b1;
        scl_s <= 1'b1; sda_s <= 1'b1;
        sda_oe <= 1'b0; scl_oe <= 1'b0;
        addr_seen <= 1'b0;
        for (bi = 0; bi < 16; bi = bi + 1) cbuf[bi] <= 8'd0;
    end else begin
        scl_s <= scl_in; scl_d <= scl_s;
        sda_s <= sda_in; sda_d <= sda_s;
        addr_seen <= 1'b0;

        if (i2c_stop && state != S_IDLE) begin
            state  <= S_IDLE;
            sda_oe <= 1'b0;
            scl_oe <= 1'b0;
        end else case (state)
            S_IDLE: begin
                sda_oe <= 1'b0;
                scl_oe <= 1'b0;
                if (i2c_start) begin
                    state   <= S_ADDR;
                    bit_cnt <= 4'd0;
                end
            end

            S_ADDR: begin
                if (scl_rise) begin
                    shift <= {shift[6:0], sda_s};
                    if (bit_cnt == 4'd7) begin
                        state   <= S_AACK0;
                        bit_cnt <= 4'd0;
                    end else bit_cnt <= bit_cnt + 4'd1;
                end
            end

            S_AACK0: begin
                if (scl_fall) begin
                    // drive ACK only when address matches
                    // shift holds {addr6..0, rw} -> shift[7:1]=addr
                    sda_oe <= (shift[7:1] == ADDR);
                    rw_bit <= shift[0];
                    state  <= S_AACK1;
                end
            end

            S_AACK1: begin
                if (scl_rise) addr_seen <= (shift[7:1] == ADDR);
                if (scl_fall) begin
                    sda_oe   <= 1'b0;
                    byte_cnt <= 5'd0;
                    bit_cnt  <= 4'd0;
                    state    <= S_AACK2;
                end
            end

            S_AACK2: begin
                if (shift[7:1] != ADDR) begin
                    state <= S_IDLE;      // not for us
                end else if (rw_bit) begin
                    state   <= S_RD;      // master reads: we drive data
                    sda_oe  <= ~rd_pat[7]; // first data bit (MSB)
                    bit_cnt <= 4'd0;
                end else begin
                    state <= S_WD;
                end
            end

            // ------------------------------------------------ write to slave
            S_WD: begin
                if (scl_rise) begin
                    shift <= {shift[6:0], sda_s};
                    if (bit_cnt == 4'd7) begin
                        state   <= S_WACK0;
                        bit_cnt <= 4'd0;
                    end else bit_cnt <= bit_cnt + 4'd1;
                end
            end

            S_WACK0: begin
                if (scl_fall) begin
                    sda_oe <= 1'b1;                  // ACK
                    if (byte_cnt < 5'd16) cbuf[byte_cnt[3:0]] <= shift;
                    state  <= S_WACK1;
                end
            end

            S_WACK1: begin
                if (scl_fall) begin
                    sda_oe <= 1'b0;
                    state  <= S_WACK2;
                end
            end

            S_WACK2: begin
                if (stretch_en && (byte_cnt[3:0] == STRETCH_BYTE)) begin
                    scl_oe      <= 1'b1;
                    stretch_cnt <= STRETCH_TICKS;
                    state       <= S_STRET;
                end else begin
                    byte_cnt <= byte_cnt + 5'd1;
                    bit_cnt  <= 4'd0;
                    state    <= S_WD;
                end
            end

            S_STRET: begin
                if (stretch_cnt == 16'd0) begin
                    scl_oe   <= 1'b0;
                    byte_cnt <= byte_cnt + 5'd1;
                    bit_cnt  <= 4'd0;
                    state    <= S_WD;
                end else stretch_cnt <= stretch_cnt - 16'd1;
            end

            // ------------------------------------------------ read from slave
            S_RD: begin
                if (scl_rise) state <= S_RDH;
            end

            S_RDH: begin
                if (scl_fall) begin
                    if (bit_cnt == 4'd7) begin
                        // byte done: release for master ack bit
                        sda_oe  <= 1'b0;
                        state   <= S_RACK;
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                        sda_oe  <= ~rd_pat[6 - bit_cnt[2:0]];
                        state   <= S_RD;
                    end
                end
            end

            S_RACK: begin
                if (scl_rise) begin
                    rw_bit <= sda_s;         // 0 = master ACK, 1 = NACK
                    state  <= S_RACK2;
                end
            end

            S_RACK2: begin
                if (scl_fall) begin
                    if (rw_bit) begin
                        state <= S_IDLE;     // master nacked: wait for stop
                    end else begin
                        byte_cnt <= byte_cnt + 5'd1;
                        bit_cnt  <= 4'd0;
                        sda_oe   <= ~rd_pat_next[7]; // next pattern byte MSB
                        state    <= S_RD;
                    end
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
