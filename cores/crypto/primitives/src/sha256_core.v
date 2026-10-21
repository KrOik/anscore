// ============================================================================
// sha256_core : SHA-256 hash engine (FIPS-180-4), byte-serial streaming input.
//
// Feed message bytes on din with din_valid=1; mark the final byte with
// din_last=1 (same beat). The core appends the 0x80 pad, zero fill and the
// 64-bit big-endian bit length itself, then emits digest + digest_valid.
// din_ready is low while a 64-round compression is running (backpressure).
// init (1 clk_en beat) re-loads the IV to start a new message; after reset
// the core is already initialized, so init is only needed between messages.
//
// Protocol (clk_en-gated, active-low async reset):
//   [init] -> din/din_valid ... din/din_valid/din_last -> digest_valid
//   digest = {H0..H7}, H0 in digest[255:224] (matches hex digest byte order).
//
// One 16x32 message-schedule shift register; 1 round per clk_en beat.
// No DSP, no BSRAM.
// ============================================================================
module sha256_core (
    input  wire         clk,
    input  wire         clk_en,
    input  wire         rst_n,
    input  wire         init,
    input  wire [7:0]   din,
    input  wire         din_valid,
    input  wire         din_last,
    output wire         din_ready,
    output wire [255:0] digest,
    output reg          digest_valid
);

localparam [2:0] S_IN    = 3'd0;
localparam [2:0] S_PAD   = 3'd1;
localparam [2:0] S_ROUND = 3'd2;
localparam [2:0] S_DONE  = 3'd3;

// pad phases inside S_PAD
localparam [1:0] P_80   = 2'd0;   // next pad byte is 0x80
localparam [1:0] P_ZERO = 2'd1;   // zero fill until bpos==56
localparam [1:0] P_LEN  = 2'd2;   // 8 length bytes at bpos 56..63

// ---------------------------------------------------------------------------
// SHA-256 round constants K[0..63]
// ---------------------------------------------------------------------------
function [31:0] k_const;
    input [5:0] t;
    begin
        case (t)
            6'd0:  k_const = 32'h428a2f98; 6'd1:  k_const = 32'h71374491;
            6'd2:  k_const = 32'hb5c0fbcf; 6'd3:  k_const = 32'he9b5dba5;
            6'd4:  k_const = 32'h3956c25b; 6'd5:  k_const = 32'h59f111f1;
            6'd6:  k_const = 32'h923f82a4; 6'd7:  k_const = 32'hab1c5ed5;
            6'd8:  k_const = 32'hd807aa98; 6'd9:  k_const = 32'h12835b01;
            6'd10: k_const = 32'h243185be; 6'd11: k_const = 32'h550c7dc3;
            6'd12: k_const = 32'h72be5d74; 6'd13: k_const = 32'h80deb1fe;
            6'd14: k_const = 32'h9bdc06a7; 6'd15: k_const = 32'hc19bf174;
            6'd16: k_const = 32'he49b69c1; 6'd17: k_const = 32'hefbe4786;
            6'd18: k_const = 32'h0fc19dc6; 6'd19: k_const = 32'h240ca1cc;
            6'd20: k_const = 32'h2de92c6f; 6'd21: k_const = 32'h4a7484aa;
            6'd22: k_const = 32'h5cb0a9dc; 6'd23: k_const = 32'h76f988da;
            6'd24: k_const = 32'h983e5152; 6'd25: k_const = 32'ha831c66d;
            6'd26: k_const = 32'hb00327c8; 6'd27: k_const = 32'hbf597fc7;
            6'd28: k_const = 32'hc6e00bf3; 6'd29: k_const = 32'hd5a79147;
            6'd30: k_const = 32'h06ca6351; 6'd31: k_const = 32'h14292967;
            6'd32: k_const = 32'h27b70a85; 6'd33: k_const = 32'h2e1b2138;
            6'd34: k_const = 32'h4d2c6dfc; 6'd35: k_const = 32'h53380d13;
            6'd36: k_const = 32'h650a7354; 6'd37: k_const = 32'h766a0abb;
            6'd38: k_const = 32'h81c2c92e; 6'd39: k_const = 32'h92722c85;
            6'd40: k_const = 32'ha2bfe8a1; 6'd41: k_const = 32'ha81a664b;
            6'd42: k_const = 32'hc24b8b70; 6'd43: k_const = 32'hc76c51a3;
            6'd44: k_const = 32'hd192e819; 6'd45: k_const = 32'hd6990624;
            6'd46: k_const = 32'hf40e3585; 6'd47: k_const = 32'h106aa070;
            6'd48: k_const = 32'h19a4c116; 6'd49: k_const = 32'h1e376c08;
            6'd50: k_const = 32'h2748774c; 6'd51: k_const = 32'h34b0bcb5;
            6'd52: k_const = 32'h391c0cb3; 6'd53: k_const = 32'h4ed8aa4a;
            6'd54: k_const = 32'h5b9cca4f; 6'd55: k_const = 32'h682e6ff3;
            6'd56: k_const = 32'h748f82ee; 6'd57: k_const = 32'h78a5636f;
            6'd58: k_const = 32'h84c87814; 6'd59: k_const = 32'h8cc70208;
            6'd60: k_const = 32'h90befffa; 6'd61: k_const = 32'ha4506ceb;
            6'd62: k_const = 32'hbef9a3f7; 6'd63: k_const = 32'hc67178f2;
            default: k_const = 32'h00000000;
        endcase
    end
endfunction

function [31:0] ror;
    input [31:0] x;
    input [4:0]  n;
    begin
        ror = (x >> n) | (x << (32 - n));
    end
endfunction

function [31:0] sig0;   // small sigma 0 (message schedule)
    input [31:0] x;
    begin
        sig0 = ror(x, 5'd7) ^ ror(x, 5'd18) ^ (x >> 3);
    end
endfunction

function [31:0] sig1;   // small sigma 1 (message schedule)
    input [31:0] x;
    begin
        sig1 = ror(x, 5'd17) ^ ror(x, 5'd19) ^ (x >> 10);
    end
endfunction

function [31:0] big0;   // capital Sigma 0
    input [31:0] x;
    begin
        big0 = ror(x, 5'd2) ^ ror(x, 5'd13) ^ ror(x, 5'd22);
    end
endfunction

function [31:0] big1;   // capital Sigma 1
    input [31:0] x;
    begin
        big1 = ror(x, 5'd6) ^ ror(x, 5'd11) ^ ror(x, 5'd25);
    end
endfunction

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
reg [2:0]  state;
reg [31:0] h0, h1, h2, h3, h4, h5, h6, h7;   // chaining value
reg [31:0] a, b, c, d, e, f, g, hh;          // working variables
reg [31:0] m [0:15];                          // message schedule shift reg
reg [5:0]  t;                                 // round counter 0..63
reg [5:0]  bpos;                              // byte position in block 0..63
reg [31:0] wacc;                              // byte->word assembler
reg [63:0] mlen;                              // message length in bytes
reg [1:0]  pad_phase;                         // P_80 / P_ZERO / P_LEN
reg        last_seen;                         // din_last received
reg        last_blk;                          // current block is the final one

assign din_ready = (state == S_IN);
assign digest = {h0, h1, h2, h3, h4, h5, h6, h7};

// Message schedule: wt = m[0]; new word appended at m[15] every round.
wire [31:0] wnew = sig1(m[14]) + m[9] + sig0(m[1]) + m[0];
wire [31:0] t1 = hh + big1(e) + ((e & f) ^ (~e & g)) + k_const(t) + m[0];
wire [31:0] t2 = big0(a) + ((a & b) ^ (a & c) ^ (b & c));

// Length field: 64-bit big-endian bit count; index = bpos[2:0] at bpos 56..63.
wire [63:0] lenbits  = {mlen[60:0], 3'b000};
wire [7:0]  len_byte = lenbits[63 - {bpos[2:0], 3'b000} -: 8];

wire [7:0] pad_byte = (pad_phase == P_80) ? 8'h80 :
                      (pad_phase == P_LEN) ? len_byte : 8'h00;

integer mi;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IN;
        h0 <= 32'h6a09e667; h1 <= 32'hbb67ae85;
        h2 <= 32'h3c6ef372; h3 <= 32'ha54ff53a;
        h4 <= 32'h510e527f; h5 <= 32'h9b05688c;
        h6 <= 32'h1f83d9ab; h7 <= 32'h5be0cd19;
        a <= 32'd0; b <= 32'd0; c <= 32'd0; d <= 32'd0;
        e <= 32'd0; f <= 32'd0; g <= 32'd0; hh <= 32'd0;
        t <= 6'd0;
        bpos <= 6'd0;
        wacc <= 32'd0;
        mlen <= 64'd0;
        pad_phase <= P_80;
        last_seen <= 1'b0;
        last_blk <= 1'b0;
        digest_valid <= 1'b0;
        for (mi = 0; mi < 16; mi = mi + 1) m[mi] <= 32'd0;
    end else if (clk_en) begin
        if (init) begin
            state <= S_IN;
            h0 <= 32'h6a09e667; h1 <= 32'hbb67ae85;
            h2 <= 32'h3c6ef372; h3 <= 32'ha54ff53a;
            h4 <= 32'h510e527f; h5 <= 32'h9b05688c;
            h6 <= 32'h1f83d9ab; h7 <= 32'h5be0cd19;
            t <= 6'd0;
            bpos <= 6'd0;
            wacc <= 32'd0;
            mlen <= 64'd0;
            pad_phase <= P_80;
            last_seen <= 1'b0;
            last_blk <= 1'b0;
            digest_valid <= 1'b0;
        end else begin
            // Both loading and compression move whole words in the same
            // direction. After sixteen appended input/padding words m[0]
            // is the first block word, exactly as for indexed loading.
            // Reuse that shift path instead of a per-word write mux/decoder.
            if (state == S_ROUND ||
                (bpos[1:0] == 2'd3 &&
                 (state == S_PAD || (state == S_IN && din_valid)))) begin
                for (mi = 0; mi < 15; mi = mi + 1) m[mi] <= m[mi + 1];
                m[15] <= (state == S_ROUND) ? wnew :
                         {wacc[23:0], (state == S_PAD) ? pad_byte : din};
            end
            case (state)
                // ------------------------------------------------------------
                // message byte input; one byte per clk_en beat
                S_IN: begin
                    if (din_valid) begin
                        wacc <= {wacc[23:0], din};
                        mlen <= mlen + 64'd1;
                        if (bpos == 6'd63) begin
                            bpos <= 6'd0;
                            state <= S_ROUND;
                            t <= 6'd0;
                            a <= h0; b <= h1; c <= h2; d <= h3;
                            e <= h4; f <= h5; g <= h6; hh <= h7;
                        end else begin
                            bpos <= bpos + 6'd1;
                        end
                        if (din_last) begin
                            last_seen <= 1'b1;
                            pad_phase <= P_80;
                            if (bpos != 6'd63) state <= S_PAD;
                        end
                    end
                end

                // ------------------------------------------------------------
                // padding: 0x80, zeros to bpos==56, then 8 length bytes
                S_PAD: begin
                    wacc <= {wacc[23:0], pad_byte};
                    case (pad_phase)
                        P_80:   pad_phase <= (bpos == 6'd55) ? P_LEN : P_ZERO;
                        P_ZERO: if (bpos == 6'd55) pad_phase <= P_LEN;
                        default: pad_phase <= pad_phase;
                    endcase
                    if (bpos == 6'd63) begin
                        bpos <= 6'd0;
                        state <= S_ROUND;
                        t <= 6'd0;
                        a <= h0; b <= h1; c <= h2; d <= h3;
                        e <= h4; f <= h5; g <= h6; hh <= h7;
                        // last length byte just went in -> this block is final
                        if (pad_phase == P_LEN) last_blk <= 1'b1;
                    end else begin
                        bpos <= bpos + 6'd1;
                    end
                end

                // ------------------------------------------------------------
                // 64-round compression, one round per clk_en beat
                S_ROUND: begin
                    if (t == 6'd63) begin
                        h0 <= h0 + (t1 + t2); h1 <= h1 + a;
                        h2 <= h2 + b;         h3 <= h3 + c;
                        h4 <= h4 + (d + t1);  h5 <= h5 + e;
                        h6 <= h6 + f;         h7 <= h7 + g;
                        state <= last_blk ? S_DONE :
                                 (last_seen ? S_PAD : S_IN);
                    end else begin
                        a <= t1 + t2;
                        b <= a;
                        c <= b;
                        d <= c;
                        e <= d + t1;
                        f <= e;
                        g <= f;
                        hh <= g;
                        t <= t + 6'd1;
                    end
                end

                // ------------------------------------------------------------
                S_DONE: begin
                    digest_valid <= 1'b1;
                end

                default: state <= S_IN;
            endcase
        end
    end
end

endmodule
