// ============================================================================
// crypto_selftest : unit selftest aggregator for the crypto_20k IP batch.
// 5 units, each drives a deterministic stimulus, folds emitted bytes into an
// FNV-1a 32-bit digest, compares against EXP_* constants produced by the
// independent Python golden model (tools/golden_model.py; sources: FIPS-197
// vectors + pycryptodome for AES, hashlib.sha256 for SHA-256, binascii.crc32
// + bit model for CRC).
//
//   U0 AESB  : aes128_core, 4 ECB encrypt vectors (FIPS-197 C.1/B + 2 model)
//   U1 SHAB  : sha256_core, 3 messages: "abc" (1 blk), 56B std vector (2 blk),
//              100B formula pattern (2 blk)
//   U2 CRC8  : crc_core mode 0 (poly 0x07), 64-byte stream
//   U3 CR16  : crc_core mode 1 (poly 0x1021 CCITT-FALSE), same stream
//   U4 CR32  : crc_core mode 2 (poly 0x04C11DB7 reflected), same stream
//
// All DUTs run on clk_en = ce (1 clk in 16) so deep combinational chains
// settle; stimulus/sampling steps happen on the same logical beats.
// ============================================================================
module crypto_selftest #(
    parameter [7:0] UNIT_EN = 8'h1F
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         all_done,
    output reg         all_pass,
    output reg         any_fail,
    input  wire [4:0]  digest_sel,
    output reg  [31:0] digest_q,
    output wire [15:0] done_mask,
    output wire [15:0] pass_mask
);

function [31:0] fnv;
    input [31:0] h;
    input [7:0]  b;
    reg [31:0] x;
    begin
        x = h ^ {24'd0, b};
        // FNV-1a prime 0x01000193 bits {0,1,4,7,8,24}: shift-add, no DSP.
        fnv = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
    end
endfunction

// fold 8 bytes of w (MSB first) into h
function [31:0] fnv8;
    input [31:0] h;
    input [63:0] w;
    begin
        fnv8 = fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(h,
            w[63:56]), w[55:48]), w[47:40]), w[39:32]),
            w[31:24]), w[23:16]), w[15:8]), w[7:0]);
    end
endfunction

// fold 4 bytes of w (MSB first) into h
function [31:0] fnv4;
    input [31:0] h;
    input [31:0] w;
    begin
        fnv4 = fnv(fnv(fnv(fnv(h, w[31:24]), w[23:16]), w[15:8]), w[7:0]);
    end
endfunction

// ---------------------------------------------------------------------------
// Beat-rate clock enable (divide by 16) -- see SOP Phase 1.
// ---------------------------------------------------------------------------
reg [3:0] ce_div = 4'd0;
wire ce = (ce_div == 4'd15);
always @(posedge clk) ce_div <= ce_div + 4'd1;

// ---------------------------------------------------------------------------
// Stimulus data sources (shared with tools/golden_model.py)
// ---------------------------------------------------------------------------

// AES vectors
function [127:0] aes_key_v;
    input [1:0] i;
    begin
        case (i)
            2'd0: aes_key_v = 128'h000102030405060708090a0b0c0d0e0f;
            2'd1: aes_key_v = 128'h00000000000000000000000000000000;
            2'd2: aes_key_v = 128'h2b7e151628aed2a6abf7158809cf4f3c;
            default: aes_key_v = 128'hd5f0e1d2c3b4a5968778695a4b3c2d1e;
        endcase
    end
endfunction

function [127:0] aes_din_v;
    input [1:0] i;
    begin
        case (i)
            2'd0: aes_din_v = 128'h00112233445566778899aabbccddeeff;
            2'd1: aes_din_v = 128'h00000000000000000000000000000000;
            2'd2: aes_din_v = 128'h6bc1bee22e409f96e93d7e117393172a;
            default: aes_din_v = 128'h00102030405060708090a0b0c0d0e0f0;
        endcase
    end
endfunction

// SHA-256 messages: byte of message m at index i (i < sha_len(m))
localparam [447:0] SHA_MSG1 =
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"; // 56 bytes

function [6:0] sha_len;
    input [1:0] m;
    begin
        case (m)
            2'd0:    sha_len = 7'd3;
            2'd1:    sha_len = 7'd56;
            default: sha_len = 7'd100;
        endcase
    end
endfunction

function [7:0] sha_byte;
    input [1:0] m;
    input [6:0] i;
    begin
        if (m == 2'd0) begin
            case (i)
                7'd0:    sha_byte = 8'h61;   // 'a'
                7'd1:    sha_byte = 8'h62;   // 'b'
                default: sha_byte = 8'h63;   // 'c'
            endcase
        end else if (m == 2'd1) begin
            sha_byte = SHA_MSG1[447 - {i, 3'b000} -: 8];
        end else begin
            // msg2: 100-byte pattern (i*31 + (i>>2) + 7) & 0xFF, i*31 = i<<5 - i
            sha_byte = ({i, 5'b00000} - {5'b00000, i})
                       + {7'b0000000, i[6:2]} + 12'd7;
        end
    end
endfunction

// CRC byte stream: j<9 -> "123456789", else (j*37 + (j>>1) + 0x11) & 0xFF
// j*37 = (j<<5)+(j<<2)+j  -- shift-add, no DSP.
function [7:0] crc_byte;
    input [6:0] j;
    begin
        if (j < 7'd9)
            crc_byte = 8'h31 + j[3:0];          // '1'..'9'
        else
            crc_byte = {j, 5'b00000} + {3'b000, j, 2'b00} + {5'b00000, j}
                       + {6'b000000, j[6:1]} + 12'h011;
    end
endfunction

// ===========================================================================
// Unit 0: aes128_core (4 ECB encrypt vectors)
// ===========================================================================
localparam [31:0] EXP_AES = 32'h61c7d1cf;   // tools/golden_model.py
reg [1:0]  aes_st = 2'd0;
reg [1:0]  aes_vi = 2'd0;
reg        aes_start = 1'b0;
reg        aes_done = 1'b0;
reg [31:0] aes_dg = 32'h811c9dc5;
wire [127:0] aes_dout;
wire aes_done_w, aes_busy;

generate
if (UNIT_EN[0]) begin : g_u0
aes128_core u_aes (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .start(aes_start), .key(aes_key_v(aes_vi)), .din(aes_din_v(aes_vi)),
    .dout(aes_dout), .done(aes_done_w), .busy(aes_busy)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        aes_st <= 2'd0; aes_vi <= 2'd0; aes_start <= 1'b0;
        aes_done <= 1'b0; aes_dg <= 32'h811c9dc5;
    end else if (ce && !aes_done) begin
        aes_start <= 1'b0;
        case (aes_st)
            2'd0: begin
                aes_start <= 1'b1;
                aes_st <= 2'd1;
            end
            2'd1: begin
                if (aes_done_w) aes_st <= 2'd2;
            end
            2'd2: begin                       // fold dout[127:64]
                aes_dg <= fnv8(aes_dg, aes_dout[127:64]);
                aes_st <= 2'd3;
            end
            default: begin                    // fold dout[63:0], next vector
                aes_dg <= fnv8(aes_dg, aes_dout[63:0]);
                aes_st <= 2'd0;
                if (aes_vi == 2'd3) aes_done <= 1'b1;
                else                aes_vi <= aes_vi + 2'd1;
            end
        endcase
    end
end
end else begin : g_u0_off
    always @(posedge clk) aes_done <= 1'b1;
end
endgenerate

// ===========================================================================
// Unit 1: sha256_core (3 messages, multi-block covered)
// ===========================================================================
localparam [31:0] EXP_SHA = 32'h566acea2;   // tools/golden_model.py
reg [2:0]  sh_st = 3'd0;
reg [1:0]  sh_msg = 2'd0;
reg [6:0]  sh_idx = 7'd0;
reg [1:0]  sh_fold = 2'd0;
reg        sh_init = 1'b0;
reg        sh_done = 1'b0;
reg [31:0] sh_dg = 32'h811c9dc5;
wire [255:0] sh_digest;
wire sh_dv_w, sh_ready, sh_dlast;

assign sh_dv_w  = (sh_st == 3'd2) && sh_ready;
assign sh_dlast = sh_dv_w && (sh_idx == (sha_len(sh_msg) - 7'd1));

generate
if (UNIT_EN[1]) begin : g_u1
wire sh_dvld;
sha256_core u_sha (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .init(sh_init),
    .din(sha_byte(sh_msg, sh_idx)), .din_valid(sh_dv_w), .din_last(sh_dlast),
    .din_ready(sh_ready),
    .digest(sh_digest), .digest_valid(sh_dvld)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sh_st <= 3'd0; sh_msg <= 2'd0; sh_idx <= 7'd0; sh_fold <= 2'd0;
        sh_init <= 1'b0; sh_done <= 1'b0; sh_dg <= 32'h811c9dc5;
    end else if (ce && !sh_done) begin
        sh_init <= 1'b0;
        case (sh_st)
            3'd0: begin                       // init pulse for this message
                sh_init <= 1'b1;
                sh_st <= 3'd1;
            end
            3'd1: begin
                sh_idx <= 7'd0;
                sh_st <= 3'd2;
            end
            3'd2: begin                       // stream bytes (din_valid wire)
                if (sh_ready) begin
                    if (sh_dlast) sh_st <= 3'd3;
                    sh_idx <= sh_idx + 7'd1;
                end
            end
            3'd3: begin                       // wait digest_valid
                if (sh_dvld) begin
                    sh_fold <= 2'd0;
                    sh_st <= 3'd4;
                end
            end
            default: begin                    // fold digest, 8B per beat
                case (sh_fold)
                    2'd0: sh_dg <= fnv8(sh_dg, sh_digest[255:192]);
                    2'd1: sh_dg <= fnv8(sh_dg, sh_digest[191:128]);
                    2'd2: sh_dg <= fnv8(sh_dg, sh_digest[127:64]);
                    default: begin
                        sh_dg <= fnv8(sh_dg, sh_digest[63:0]);
                        sh_st <= 3'd0;
                        if (sh_msg == 2'd2) sh_done <= 1'b1;
                        else                sh_msg <= sh_msg + 2'd1;
                    end
                endcase
                if (sh_fold != 2'd3) sh_fold <= sh_fold + 2'd1;
            end
        endcase
    end
end
end else begin : g_u1_off
    always @(posedge clk) sh_done <= 1'b1;
end
endgenerate

// ===========================================================================
// Units 2/3/4: crc_core at fixed modes over the shared 64-byte stream
// ===========================================================================
localparam [31:0] EXP_CRC8  = 32'hfd957a4b;
localparam [31:0] EXP_CRC16 = 32'hd0771e60;
localparam [31:0] EXP_CRC32 = 32'h720d8b44;

// --- Unit 2: CRC-8/SMBUS -----------------------------------------------------
reg [2:0]  c8_st = 3'd0;
reg [6:0]  c8_idx = 7'd0;
reg        c8_init = 1'b0;
reg        c8_done = 1'b0;
reg [31:0] c8_dg = 32'h811c9dc5;
wire [31:0] c8_out;

generate
if (UNIT_EN[2]) begin : g_u2
crc_core u_crc8 (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .mode(2'd0), .init(c8_init),
    .din(crc_byte(c8_idx)), .din_valid(c8_st == 3'd2),
    .crc_out(c8_out)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        c8_st <= 3'd0; c8_idx <= 7'd0; c8_init <= 1'b0;
        c8_done <= 1'b0; c8_dg <= 32'h811c9dc5;
    end else if (ce && !c8_done) begin
        c8_init <= 1'b0;
        case (c8_st)
            3'd0: begin c8_init <= 1'b1; c8_st <= 3'd1; end
            3'd1: begin c8_idx <= 7'd0;  c8_st <= 3'd2; end
            3'd2: begin                     // 64 bytes, one per beat
                if (c8_idx == 7'd63) c8_st <= 3'd3;
                c8_idx <= c8_idx + 7'd1;
            end
            3'd3: c8_st <= 3'd4;            // settle one beat
            default: begin                  // fold final crc_out
                c8_dg <= fnv4(c8_dg, c8_out);
                c8_done <= 1'b1;
            end
        endcase
    end
end
end else begin : g_u2_off
    always @(posedge clk) c8_done <= 1'b1;
end
endgenerate

// --- Unit 3: CRC-16/CCITT-FALSE ----------------------------------------------
reg [2:0]  c16_st = 3'd0;
reg [6:0]  c16_idx = 7'd0;
reg        c16_init = 1'b0;
reg        c16_done = 1'b0;
reg [31:0] c16_dg = 32'h811c9dc5;
wire [31:0] c16_out;

generate
if (UNIT_EN[3]) begin : g_u3
crc_core u_crc16 (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .mode(2'd1), .init(c16_init),
    .din(crc_byte(c16_idx)), .din_valid(c16_st == 3'd2),
    .crc_out(c16_out)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        c16_st <= 3'd0; c16_idx <= 7'd0; c16_init <= 1'b0;
        c16_done <= 1'b0; c16_dg <= 32'h811c9dc5;
    end else if (ce && !c16_done) begin
        c16_init <= 1'b0;
        case (c16_st)
            3'd0: begin c16_init <= 1'b1; c16_st <= 3'd1; end
            3'd1: begin c16_idx <= 7'd0;  c16_st <= 3'd2; end
            3'd2: begin
                if (c16_idx == 7'd63) c16_st <= 3'd3;
                c16_idx <= c16_idx + 7'd1;
            end
            3'd3: c16_st <= 3'd4;
            default: begin
                c16_dg <= fnv4(c16_dg, c16_out);
                c16_done <= 1'b1;
            end
        endcase
    end
end
end else begin : g_u3_off
    always @(posedge clk) c16_done <= 1'b1;
end
endgenerate

// --- Unit 4: CRC-32/ISO-HDLC --------------------------------------------------
reg [2:0]  c32_st = 3'd0;
reg [6:0]  c32_idx = 7'd0;
reg        c32_init = 1'b0;
reg        c32_done = 1'b0;
reg [31:0] c32_dg = 32'h811c9dc5;
wire [31:0] c32_out;

generate
if (UNIT_EN[4]) begin : g_u4
crc_core u_crc32 (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .mode(2'd2), .init(c32_init),
    .din(crc_byte(c32_idx)), .din_valid(c32_st == 3'd2),
    .crc_out(c32_out)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        c32_st <= 3'd0; c32_idx <= 7'd0; c32_init <= 1'b0;
        c32_done <= 1'b0; c32_dg <= 32'h811c9dc5;
    end else if (ce && !c32_done) begin
        c32_init <= 1'b0;
        case (c32_st)
            3'd0: begin c32_init <= 1'b1; c32_st <= 3'd1; end
            3'd1: begin c32_idx <= 7'd0;  c32_st <= 3'd2; end
            3'd2: begin
                if (c32_idx == 7'd63) c32_st <= 3'd3;
                c32_idx <= c32_idx + 7'd1;
            end
            3'd3: c32_st <= 3'd4;
            default: begin
                c32_dg <= fnv4(c32_dg, c32_out);
                c32_done <= 1'b1;
            end
        endcase
    end
end
end else begin : g_u4_off
    always @(posedge clk) c32_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Aggregation
// ---------------------------------------------------------------------------
wire [4:0] done_w = {c32_done, c16_done, c8_done, sh_done, aes_done};
assign done_mask = {11'd0, done_w};

function [31:0] exp_digest;
    input [2:0] idx;
    begin
        case (idx)
            3'd0:    exp_digest = EXP_AES;
            3'd1:    exp_digest = EXP_SHA;
            3'd2:    exp_digest = EXP_CRC8;
            3'd3:    exp_digest = EXP_CRC16;
            3'd4:    exp_digest = EXP_CRC32;
            default: exp_digest = 32'd0;
        endcase
    end
endfunction

reg [31:0] digests [0:7];
reg [7:0]  pass_r;
assign pass_mask = {8'd0, pass_r};

integer ui;
always @(posedge clk) begin
    digests[0] <= aes_dg;  digests[1] <= sh_dg;
    digests[2] <= c8_dg;   digests[3] <= c16_dg;
    digests[4] <= c32_dg;
    digests[5] <= 32'd0;   digests[6] <= 32'd0;   digests[7] <= 32'd0;
    for (ui = 0; ui < 8; ui = ui + 1) begin
        if (ui < 5)
            pass_r[ui] <= done_w[ui] &&
                          (!UNIT_EN[ui] || digests[ui] === exp_digest(ui[2:0]));
        else
            pass_r[ui] <= 1'b0;
    end
end

always @(*) begin
    digest_q = digests[digest_sel[2:0]];
end

// verdict latch: pass_r settles one cycle after last done bit (===, X fails)
reg verdict_settled;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        all_done <= 1'b0; all_pass <= 1'b0; any_fail <= 1'b0;
        verdict_settled <= 1'b0;
    end else if (ce && !all_done) begin
        all_done <= &done_w;
    end else if (!verdict_settled) begin
        verdict_settled <= 1'b1;
        all_pass <= (pass_r === {3'b000, done_w});
        any_fail <= (pass_r !== {3'b000, done_w});
    end
end

endmodule
