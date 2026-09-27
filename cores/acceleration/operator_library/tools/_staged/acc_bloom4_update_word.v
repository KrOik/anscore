// Staged candidate 2 for acc_bloom4_update: parallel write decode done as
// eight 32-bit word lanes instead of a 256-bit one-hot comparator per bit.
// Candidate 1 (acc_bloom4_update_flat.v) is behaviourally right but extracts
// 52748 AND gates because it compares all 16 positions against all 256 bit
// indices; a Bloom set is really "word p[7:3] gets bit p[2:0]", which costs an
// 8 x 16 mux array instead. Function, ports, vectors and latency are unchanged.
module acc_bloom4_update (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg [255:0] state_r;
reg [255:0] pre, set_mask, state_n;
reg [127:0] posv;                     // 16 positions, 8 bits each
reg [511:0] shv;                      // 16 one-bit masks, 32 bits each
reg [15:0] hitv, newv;
reg [7:0] digest;
reg [8:0] n_before, n_after, n_set;
reg [31:0] k, h0, h1, acc;
reg [31:0] r, x, accw;
reg [7:0] tb;
reg [2:0] wsel;
reg f, n_query, dupm;
integer lane, j, m, i, W;

assign in_ready = clk_en && (!out_valid || out_ready);

always @* begin
    // every temp is defaulted here: a non-defaulted decl= temp infers a latch
    // and yosys hangs in PROC_DLATCH.
    pre = 256'd0; set_mask = 256'd0; state_n = state_r;
    posv = 128'd0; shv = 512'd0; hitv = 16'd0; newv = 16'd0; digest = 8'h00;
    n_before = 9'd0; n_after = 9'd0; n_set = 9'd0;
    k = 32'd0; h0 = 32'd0; h1 = 32'd0; acc = 32'd0;
    r = 32'd0; x = 32'd0; accw = 32'd0; tb = 8'd0; wsel = 3'd0;
    f = 1'b0; n_query = 1'b0; dupm = 1'b0;
    lane = 0; j = 0; m = 0; i = 0; W = 0;

    if (c[30:9] != 22'd0) begin
        f = 1'b1;
    end else begin
        n_query = c[8];
        pre = c[31] ? 256'd0 : state_r;

        for (lane = 0; lane < 4; lane = lane + 1) begin
            if (lane == 0) k = {16'd0, a[15:0]};
            else if (lane == 1) k = {16'd0, a[31:16]};
            else if (lane == 2) k = {16'd0, b[15:0]};
            else k = {16'd0, b[31:16]};
            h0 = ((((k >> 8) ^ k) & 32'h0000_00ff) ^ {24'd0, c[7:0]}) & 32'h0000_00ff;
            h1 = (((((k >> 12) ^ (k >> 8) ^ (k >> 4) ^ k) & 32'h0000_000f)
                   ^ {24'd0, c[7:4]}) & 32'h0000_000f) | 32'h0000_0001;
            acc = h0;
            for (j = 0; j < 4; j = j + 1) begin
                tb = acc[7:0];
                posv[8*((lane*4)+j) +: 8] = tb;
                hitv[(lane*4)+j] = ~pre[tb];          // inverted: lane hit = all zero
                shv[32*((lane*4)+j) +: 32] = 32'd1 << tb[4:0];
                acc = acc + h1;
            end
        end

        // program-order precedence: a position counts as new only if no earlier
        // position of this beat already claimed the same bit.
        newv = 16'd0;
        for (m = 0; m < 16; m = m + 1) begin
            dupm = 1'b0;
            tb = posv[8*m +: 8];
            for (i = 0; i < 16; i = i + 1)
                if (i < m && newv[i] && posv[8*i +: 8] == tb) dupm = 1'b1;
            newv[m] = ~n_query & ~pre[tb] & ~dupm;
        end

        // write decode: word W collects every new position whose high five bits
        // name it. At most one new position can name a given bit, so ORing the
        // word masks cannot lose a set.
        for (W = 0; W < 8; W = W + 1) begin
            wsel = W;                     // W is 0..7, truncates to 3 bits
            accw = 32'd0;
            for (m = 0; m < 16; m = m + 1) begin
                tb = posv[8*m +: 8];
                if (newv[m] && tb[7:5] == wsel) accw = accw | shv[32*m +: 32];
            end
            set_mask[32*W +: 32] = accw;
        end

        digest = 8'h00;
        for (m = 0; m < 16; m = m + 1)
            if (newv[m]) digest = digest ^ posv[8*m +: 8];

        n_before = 9'd0;
        for (i = 0; i < 256; i = i + 1) if (pre[i]) n_before = n_before + 9'd1;
        n_set = 9'd0;
        for (m = 0; m < 16; m = m + 1) if (newv[m]) n_set = n_set + 9'd1;
        n_after = n_before + n_set;

        state_n = pre | set_mask;

        for (lane = 0; lane < 4; lane = lane + 1) begin
            if (!hitv[lane*4] && !hitv[lane*4+1] && !hitv[lane*4+2] && !hitv[lane*4+3])
                r[lane] = 1'b1;
            else
                r[lane] = 1'b0;
            if (newv[lane*4] | newv[lane*4+1] | newv[lane*4+2] | newv[lane*4+3])
                r[4+lane] = 1'b1;
            else
                r[4+lane] = 1'b0;
        end
        r[15:8] = digest;
        x[8:0] = n_after;
        x[15:9] = n_set[6:0];
        x[16] = n_query;
        x[17] = (n_after > 9'd224);
        x[26:18] = n_before;
        x[27] = c[31];
        f = (n_after > 9'd224);
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_valid <= 1'b0; result <= 32'd0; aux <= 32'd0; fault <= 1'b0; state_r <= 256'd0;
    end else if (clk_en) begin
        if (in_ready) begin
            out_valid <= in_valid;
            if (in_valid) begin
                result <= r; aux <= x; fault <= f; state_r <= state_n;
            end
        end
    end
end
endmodule
