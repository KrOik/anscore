// ============================================================================
// fft_probe_top -- board probe for fft64 (v4: 4 vectors, dual-phase streams).
//   for fvec 0..3: load stim -> [0xA0|fvec][64 raw recs] -> start -> wait done
//   -> [0xB0|fvec][64 fft recs] -> next fvec. rec=[addr][re_hi][re_lo][im_lo].
// uart/dbg_uart -> A11 (LA D0).  Full-rate clk_en=1.
// ============================================================================
module fft_probe_top (
    input  wire clk,
    output wire uart_tx,
    output wire dbg_uart
);

localparam [3:0] P_LD   = 4'd0;
localparam [3:0] P_MARK = 4'd1;
localparam [3:0] P_RQ   = 4'd2;
localparam [3:0] P_RZ   = 4'd3;
localparam [3:0] P_SNAP = 4'd4;
localparam [3:0] P_SEND = 4'd5;
localparam [3:0] P_GAP  = 4'd6;
localparam [3:0] P_ST   = 4'd7;
localparam [3:0] P_WD   = 4'd8;

reg [3:0]  st;
reg [5:0]  i;
reg [4:0]  settle;
reg [1:0]  byte_i;
reg        phase2;
reg [1:0]  fvec;
reg [7:0]  tx_latched;

// power-on reset: hold rst_n low for 32 clocks
reg [5:0] por = 6'd0;
wire rst_n = por[5];
always @(posedge clk) if (!rst_n) por <= por + 6'd1;

reg        ld_en;
reg [5:0]  ld_addr;
reg signed [15:0] ld_re;
reg        start;
wire       busy, done;
reg        rd_en;
reg [5:0]  rd_addr;
wire signed [15:0] rd_re, rd_im;

// production-rate clock enable: 1 in 16 (same as sig_selftest ce)
reg [3:0] cediv = 4'd0;
wire ce = (cediv == 4'd15);
always @(posedge clk) cediv <= cediv + 4'd1;

fft64 #(.NSTAGE(`PROBE_NSTAGE)) u_fft (
`ifdef PROBE_CE16
    .clk(clk), .clk_en(ce), .rst_n(rst_n),
`else
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
`endif
    .ld_en(ld_en), .ld_addr(ld_addr), .ld_re(ld_re), .ld_im(16'sd0),
    .start(start), .busy(busy), .done(done),
    .rd_en(rd_en), .rd_addr(rd_addr), .rd_re(rd_re), .rd_im(rd_im)
);

// same stimulus as sig_selftest
reg signed [15:0] costab [0:31];
initial $readmemh("fft64_cos.mem", costab);
function signed [15:0] stim_fft;
    input [1:0] v;
    input [5:0] n;
    reg [5:0] ci;
    reg signed [15:0] c;
    begin
        case (v)
            2'd0: stim_fft = (n == 6'd0) ? 16'sd16384 : 16'sd0;
            2'd1: stim_fft = 16'sd4096;
            2'd2: begin
                ci = {n[3:0], 2'b00};
                c  = ci[5] ? -costab[ci[4:0]] : costab[ci[4:0]];
                stim_fft = c >>> 2;
            end
            default: stim_fft = n[0] ? -16'sd8192 : 16'sd8192;
        endcase
    end
endfunction

reg [15:0] snap_re, snap_im;
reg        tx_valid;
wire       tx_ready, tx_busy;

uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) uart (
    .clk(clk), .rst_n(rst_n),
    .tx_data(tx_latched), .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready), .tx_pin(dbg_uart), .tx_busy(tx_busy)
);
assign uart_tx = dbg_uart;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st <= P_LD; i <= 6'd0; byte_i <= 2'd0; phase2 <= 1'b0; fvec <= 2'd0;
        settle <= 5'd0;
        ld_en <= 1'b0; ld_addr <= 6'd0; ld_re <= 16'sd0;
        start <= 1'b0; rd_en <= 1'b0; rd_addr <= 6'd0;
        snap_re <= 16'd0; snap_im <= 16'd0; tx_valid <= 1'b0;
        tx_latched <= 8'd0;
    end else begin
    ld_en <= 1'b0; start <= 1'b0; rd_en <= 1'b0; tx_valid <= 1'b0;
    case (st)
        P_LD: begin
`ifdef PROBE_STREAD
            // selftest-style: ld_en held HIGH through each window (ce-gated
            // reg semantics); addr/data change AT each ce edge -> every write
            // edge races the address/data update (hold violation model).
            if (settle != 5'd0 || ce) ld_en <= 1'b1;   // rises at first ce edge
            if (ce) begin
                settle  <= 5'd1;
                ld_addr <= i;
                ld_re   <= stim_fft(fvec, i);
                if (i == 6'd63) begin i <= 6'd0; st <= P_LDR; end
                else i <= i + 6'd1;
            end
`else
            ld_en <= 1'b1; ld_addr <= i;
            ld_re <= stim_fft(fvec, i);
            // hold each write for 17 clks so >=1 ce edge lands inside
            if (settle == 5'd16) begin
                settle <= 5'd0;
                if (i == 6'd63) begin i <= 6'd0; phase2 <= 1'b0; st <= P_MARK; end
                else i <= i + 6'd1;
            end else settle <= settle + 5'd1;
`endif
        end
        P_LDR: begin                        // last write commits at this ce
            if (ce) begin phase2 <= 1'b0; st <= P_MARK; end  // ld_en drops AT edge
            else ld_en <= 1'b1;
        end
        P_MARK: begin                       // marker: 0xA0|fvec / 0xB0|fvec
            if (tx_ready && !tx_busy) begin
                tx_latched <= (phase2 ? 8'hB0 : 8'hA0) | {6'b0, fvec};
                tx_valid <= 1'b1;
                i <= 6'd0;
                st <= P_RQ;
            end
        end
        P_RQ: begin
`ifdef PROBE_STREAD
            // selftest-style: rd_en rises AT a ce edge, drops AT the next
            // ce edge (the capture edge) -- one-window read, hold race on re
            if (ce) begin
                rd_en <= 1'b1; rd_addr <= i;
                settle <= 5'd0;
                st <= P_RZ;
            end
`else
            rd_en <= 1'b1; rd_addr <= i;
            settle <= 5'd0;
            st <= P_RZ;
`endif
        end
        P_RZ: begin                        // hold rd_en + addr for 32 clocks
`ifdef PROBE_STREAD
            if (ce) st <= P_SNAP;          // rd_en drops AT the capture edge
            else rd_en <= 1'b1;
`else
            rd_en <= 1'b1;
            if (settle == 5'd31) st <= P_SNAP;
            else settle <= settle + 5'd1;
`endif
        end
        P_SNAP: begin
            snap_re <= rd_re; snap_im <= rd_im;
            byte_i <= 2'd0;
            st <= P_SEND;
        end
        P_SEND: begin
            if (tx_ready && !tx_busy) begin
                case (byte_i)
                    2'd0: tx_latched <= {2'b00, rd_addr};
                    2'd1: tx_latched <= snap_re[15:8];
                    2'd2: tx_latched <= snap_re[7:0];
                    default: tx_latched <= snap_im[7:0];
                endcase
                tx_valid <= 1'b1;
                if (byte_i == 2'd3) begin
                    byte_i <= 2'd0;
                    if (i == 6'd63) begin
                        i <= 6'd0;
                        settle <= 5'd0;
                        st <= phase2 ? P_NEXT : P_ST;
                    end else begin
                        i <= i + 6'd1;
                        st <= P_RQ;
                    end
                end else begin
                    byte_i <= byte_i + 2'd1;
                    st <= P_GAP;
                end
            end
        end
        P_GAP: st <= P_SEND;
        P_ST: begin
`ifdef PROBE_STREAD
            if (ce) st <= P_WD;            // start high [E1,E2): drops AT E2
            else start <= 1'b1;
`else
            start <= 1'b1;                 // hold 17 clks -> covers a ce edge
            if (settle == 5'd16) begin settle <= 5'd0; st <= P_WD; end
            else settle <= settle + 5'd1;
`endif
        end
        P_WD: begin
            if (done) begin phase2 <= 1'b1; st <= P_MARK; end
        end
        P_NEXT: begin
            fvec <= fvec + 2'd1;
            settle <= 5'd0;
            st <= P_LD;
        end
        default: st <= P_LD;
    endcase
    end
end

localparam [3:0] P_NEXT = 4'd9;
localparam [3:0] P_LDR  = 4'd10;

endmodule
