// Tang Primer 20K SD-card SPI reader top.
// Initializes the card, reads MBR, parses the first FAT partition, scans the
// root directory for the first real file, dumps its first data sector, and
// reports everything over UART at 115200 8N1.
module top #(
    parameter integer BOOT_DELAY = 13500000  // ~0.5 s at 27 MHz
) (
    input  wire clk,      // 27 MHz board oscillator (H11)
    input  wire rst_n,    // pushbutton (T10, active low)

    output wire sd_clk,   // SD CLK  (N10)
    output wire sd_mosi,  // SD CMD  (R14)
    input  wire sd_miso,  // SD DAT0 (M8)
    output wire sd_cs_n,  // SD DAT3 (N11)
    input  wire sd_det,   // card detect DET_A (D15)

    output wire uart_tx_pin  // UART TX (M11)
);

    // ------------------------------------------------------------------
    // SD reader core
    // ------------------------------------------------------------------
    reg         init_start;
    wire        init_busy, init_done;
    wire [3:0]  init_err;
    wire [7:0]  dbg_r1;
    wire [63:0] dbg_hist;
    wire [63:0] dbg_h8;
    wire [39:0] dbg_r1s;
    wire        card_v2, card_hc;
    reg         rd_start;
    reg  [31:0] rd_lba;
    wire        rd_busy, rd_done;
    wire [3:0]  rd_err;
    wire [7:0]  rd_data;
    wire        rd_dv;

    sd_wb_seq #(
`ifdef SIM
        .STARTUP_CLOCKS(75), .POWERUP_IDLE(64)
`endif
    ) sd (
        .clk(clk), .rst_n(rst_n),
        .init_start(init_start), .init_busy(init_busy),
        .init_done(init_done), .init_err(init_err), .dbg_r1(dbg_r1),
        .dbg_hist(dbg_hist), .dbg_r1s(dbg_r1s), .dbg_h8(dbg_h8),
        .card_v2(card_v2), .card_hc(card_hc),
        .rd_start(rd_start), .rd_lba(rd_lba),
        .rd_busy(rd_busy), .rd_done(rd_done), .rd_err(rd_err),
        .rd_data(rd_data), .rd_dv(rd_dv),
        .sd_cs_n(sd_cs_n), .sd_miso(sd_miso),
        .sd_sck(sd_clk), .sd_mosi(sd_mosi)
    );

    // ------------------------------------------------------------------
    // UART line printer: caller fills lb[0..len), raises line_req;
    // sender drains the buffer and lowers line_busy when done.
    // ------------------------------------------------------------------
    reg  [7:0] lb [0:111];
    reg  [6:0] lb_len;
    reg        line_req;
    reg        line_busy;
    reg  [6:0] tx_idx;
    reg        tx_valid;
    reg  [7:0] tx_data;
    wire       tx_ready;

    uart_tx #(
        .CLK_FRE(27),
        .BAUD_RATE(115200)
    ) uart (
        .clk(clk), .rst_n(rst_n),
        .tx_data(tx_data), .tx_data_valid(tx_valid),
        .tx_data_ready(tx_ready), .tx_pin(uart_tx_pin), .tx_busy()
    );

    reg tx_wait_fall;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_busy    <= 1'b0;
            tx_idx       <= 7'd0;
            tx_valid     <= 1'b0;
            tx_data      <= 8'd0;
            tx_wait_fall <= 1'b0;
        end else begin
            tx_valid <= 1'b0;
            if (line_req && !line_busy) begin
                line_busy    <= 1'b1;
                tx_idx       <= 7'd0;
                tx_wait_fall <= 1'b0;
            end else if (line_busy) begin
                if (tx_wait_fall) begin
                    if (!tx_ready) tx_wait_fall <= 1'b0;
                end else if (tx_ready) begin
                    tx_data  <= lb[tx_idx];
                    tx_valid <= 1'b1;
                    if (tx_idx == lb_len - 7'd1) begin
                        line_busy <= 1'b0;   // last byte issued
                    end else begin
                        tx_idx       <= tx_idx + 7'd1;
                        tx_wait_fall <= 1'b1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // captured fields
    // ------------------------------------------------------------------
    reg [7:0] mbr_buf [0:63];   // partition table bytes 446..509
    reg [7:0] mbr_sig0, mbr_sig1;
    reg [7:0] bpb [0:63];       // boot-sector bytes 0..63
    reg [7:0] ent [0:31];       // directory entry
    reg [7:0] fdata [0:31];     // first 32 file bytes

    reg [31:0] p_lba [0:3];
    reg [31:0] p_sz  [0:3];
    reg [7:0]  p_type [0:3];
    reg [1:0]  n_parts;

    reg        is_fat32;
    reg [31:0] bpb_bps, bpb_rsv, bpb_fatsz, bpb_re, bpb_rootcl;
    reg [7:0]  bpb_spc, bpb_nf;
    reg [31:0] root_lba, data_lba;
    reg [31:0] root_secs;
    reg [4:0]  spc_shift;
    reg [31:0] file_cl, file_sz;
    reg        file_found;
    reg [7:0]  gbuf [0:95];       // GPT header / entry scratch
    reg [31:0] gpt_elba;          // GPT partition-entries LBA
    reg [31:0] gpt_p1lba;         // first GPT partition start LBA
    reg [9:0]  byte_cnt;
    reg [4:0]  ent_off;         // 0..31 position inside current 32B entry
    reg        ent_valid;
    reg [3:0]  scan_secs;       // root dir sectors scanned
    reg [3:0]  scan_max;
    reg [31:0] mul_acc;
    reg [7:0]  mul_n;
    reg [24:0] rst_delay;
    reg        init_seen;

    localparam [5:0]
        T_RESET    = 6'd0,
        T_INIT     = 6'd1,
        T_IN_RPT   = 6'd2,
        T_MBR_RD   = 6'd3,
        T_MBR_WAIT = 6'd4,
        T_MBR_RPT  = 6'd5,
        T_P_RPT    = 6'd6,
        T_BPB_RD   = 6'd7,
        T_BPB_WAIT = 6'd8,
        T_BPB_RPT  = 6'd9,
        T_FAT_MUL  = 6'd10,
        T_ROOT_PRE = 6'd22,
        T_ROOT_RD  = 6'd11,
        T_ROOT_WAIT= 6'd12,
        T_FILE_RPT = 6'd13,
        T_DATA_LBA = 6'd14,
        T_DATA_RD  = 6'd15,
        T_DATA_WAIT= 6'd16,
        T_DATA_RPT = 6'd17,
        T_DONE     = 6'd18,
        T_ERR_RPT  = 6'd19,
        T_LINE_WAIT= 6'd20,
        T_HALT     = 6'd21,
        T_GPT_RD   = 6'd23,
        T_GPT_WAIT = 6'd24,
        T_GPT_RPT  = 6'd25,
        T_GE_RD    = 6'd26,
        T_GE_WAIT  = 6'd27,
        T_GE_RPT   = 6'd28;

    reg [5:0]  tstate;
    reg [5:0]  after_line;      // state to enter when the line finishes
    reg [1:0]  p_idx;
    reg [3:0]  err_show;

    function automatic [7:0] hx(input [3:0] n);
        hx = (n < 4'd10) ? (8'h30 + n) : (8'h41 + n - 4'd10);
    endfunction

    // compose helpers write straight into lb; caller sets lb_len/line_req
    task automatic p8h(input integer base, input [31:0] v);
        begin
            lb[base+0] <= hx(v[31:28]); lb[base+1] <= hx(v[27:24]);
            lb[base+2] <= hx(v[23:20]); lb[base+3] <= hx(v[19:16]);
            lb[base+4] <= hx(v[15:12]); lb[base+5] <= hx(v[11:8]);
            lb[base+6] <= hx(v[7:4]);   lb[base+7] <= hx(v[3:0]);
        end
    endtask

    task automatic p4h(input integer base, input [15:0] v);
        begin
            lb[base+0] <= hx(v[15:12]); lb[base+1] <= hx(v[11:8]);
            lb[base+2] <= hx(v[7:4]);   lb[base+3] <= hx(v[3:0]);
        end
    endtask

    task automatic p2h(input integer base, input [7:0] v);
        begin
            lb[base+0] <= hx(v[7:4]); lb[base+1] <= hx(v[3:0]);
        end
    endtask

    task automatic send_line(input [5:0] next_state);
        begin
            line_req   <= 1'b1;
            after_line <= next_state;
            tstate     <= T_LINE_WAIT;
        end
    endtask

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate     <= T_RESET;
            rst_delay  <= 25'd0;
            init_start <= 1'b0;
            rd_start   <= 1'b0;
            rd_lba     <= 32'd0;
            line_req   <= 1'b0;
            lb_len     <= 7'd0;
            after_line <= T_HALT;
            n_parts    <= 2'd0;
            is_fat32   <= 1'b0;
            root_lba   <= 32'd0;
            data_lba   <= 32'd0;
            root_secs  <= 32'd0;
            spc_shift  <= 5'd0;
            file_cl    <= 32'd0;
            file_sz    <= 32'd0;
            file_found <= 1'b0;
            gpt_elba   <= 32'd0;
            gpt_p1lba  <= 32'd0;
            byte_cnt   <= 10'd0;
            ent_off    <= 5'd0;
            ent_valid  <= 1'b0;
            scan_secs  <= 4'd0;
            scan_max   <= 4'd0;
            mul_acc    <= 32'd0;
            mul_n      <= 8'd0;
            p_idx      <= 2'd0;
            err_show   <= 4'd0;
            init_seen  <= 1'b0;
            bpb_bps    <= 32'd0; bpb_rsv <= 32'd0; bpb_fatsz <= 32'd0;
            bpb_re     <= 32'd0; bpb_rootcl <= 32'd0;
            bpb_spc    <= 8'd0;  bpb_nf <= 8'd0;
            for (i = 0; i < 4; i = i + 1) begin
                p_lba[i] <= 32'd0; p_sz[i] <= 32'd0; p_type[i] <= 8'd0;
            end
        end else begin
            init_start <= 1'b0;
            rd_start   <= 1'b0;
            line_req   <= 1'b0;

            // sector byte capture
            if (rd_dv) begin
                byte_cnt <= byte_cnt + 10'd1;
                case (tstate)
                    T_MBR_WAIT: begin
                        if (byte_cnt >= 10'd446 && byte_cnt < 10'd510)
                            mbr_buf[byte_cnt - 10'd446] <= rd_data;
                        if (byte_cnt == 10'd510) mbr_sig0 <= rd_data;
                        if (byte_cnt == 10'd511) mbr_sig1 <= rd_data;
                    end
                    T_BPB_WAIT: begin
                        if (byte_cnt < 10'd64) bpb[byte_cnt] <= rd_data;
                    end
                    T_ROOT_WAIT: begin
                        if (ent_off == 5'd0) begin
                            // entry first byte: skip empty/deleted; 0x00 ends dir
                            ent_valid <= (rd_data != 8'h00) &&
                                         (rd_data != 8'hE5) && !file_found;
                            if (rd_data != 8'h00 && rd_data != 8'hE5 &&
                                !file_found)
                                ent[0] <= rd_data;
                        end else if (ent_valid) begin
                            ent[ent_off] <= rd_data;
                            if (ent_off == 5'd11 &&
                                (rd_data == 8'h0F ||
                                 (rd_data & 8'h18) != 8'h00))
                                ent_valid <= 1'b0;
                        end
                        if (ent_off == 5'd31) begin
                            ent_off <= 5'd0;
                            if (ent_valid && !file_found) begin
                                file_found <= 1'b1;
                                file_cl    <= is_fat32 ?
                                              {ent[21], ent[20],
                                               ent[27], ent[26]} :
                                              {16'd0, ent[27], ent[26]};
                                file_sz    <= {rd_data, ent[30],
                                               ent[29], ent[28]};
                            end
                        end else begin
                            ent_off <= ent_off + 5'd1;
                        end
                    end
                    T_DATA_WAIT: begin
                        if (byte_cnt < 10'd32) fdata[byte_cnt] <= rd_data;
                    end
                    T_GPT_WAIT, T_GE_WAIT: begin
                        if (byte_cnt < 10'd96) gbuf[byte_cnt] <= rd_data;
                    end
                    default: ;
                endcase
            end

            case (tstate)
                T_RESET: begin
                    if (rst_delay == BOOT_DELAY[24:0]) tstate <= T_INIT;
                    else rst_delay <= rst_delay + 25'd1;
                end

                T_INIT: begin
                    init_start <= 1'b1;
                    init_seen  <= 1'b0;
                    tstate     <= T_IN_RPT;
                end

                T_IN_RPT: begin
                    if (init_busy) init_seen <= 1'b1;
                    if (!init_seen) begin
                        // wait for init to start
                    end else if (init_busy) begin
                        // still running
                    end else if (init_done) begin
                        // "IN V=x HC=x D=x\n"
                        lb[0]<="I"; lb[1]<="N"; lb[2]<=" "; lb[3]<="V"; lb[4]<="=";
                        lb[5] <= card_v2 ? "2" : "1";
                        lb[6]<=" "; lb[7]<="H"; lb[8]<="C"; lb[9]<="=";
                        lb[10]<= card_hc ? "1" : "0";
                        lb[11]<=" "; lb[12]<="D"; lb[13]<="=";
                        lb[14]<= sd_det ? "1" : "0";
                        lb[15]<=8'h0A; lb_len<=7'd16;
                        send_line(T_MBR_RD);
                    end else begin
                        // "IE=x S=xx xx xx xx xx H=<16 hex> D=x\n"
                        // S = R1 for CMD0 CMD8 CMD55 CMD41 CMD58;
                        // H = last 8 raw received bytes
                        lb[0]<="I"; lb[1]<="E"; lb[2]<="="; lb[3]<=hx(init_err);
                        lb[4]<=" "; lb[5]<="S"; lb[6]<="=";
                        p2h(7, dbg_r1s[39:32]);
                        lb[9]<=" ";  p2h(10, dbg_r1s[31:24]);
                        lb[12]<=" "; p2h(13, dbg_r1s[23:16]);
                        lb[15]<=" "; p2h(16, dbg_r1s[15:8]);
                        lb[18]<=" "; p2h(19, dbg_r1s[7:0]);
                        lb[21]<=" "; lb[22]<="H"; lb[23]<="=";
                        p2h(24, dbg_hist[63:56]);
                        p2h(26, dbg_hist[55:48]);
                        p2h(28, dbg_hist[47:40]);
                        p2h(30, dbg_hist[39:32]);
                        p2h(32, dbg_hist[31:24]);
                        p2h(34, dbg_hist[23:16]);
                        p2h(36, dbg_hist[15:8]);
                        p2h(38, dbg_hist[7:0]);
                        lb[40]<=" "; lb[41]<="8"; lb[42]<="=";
                        p2h(43, dbg_h8[63:56]);
                        p2h(45, dbg_h8[55:48]);
                        p2h(47, dbg_h8[47:40]);
                        p2h(49, dbg_h8[39:32]);
                        p2h(51, dbg_h8[31:24]);
                        p2h(53, dbg_h8[23:16]);
                        p2h(55, dbg_h8[15:8]);
                        p2h(57, dbg_h8[7:0]);
                        lb[59]<=" "; lb[60]<="D"; lb[61]<="=";
                        lb[62]<= sd_det ? "1" : "0";
                        lb[63]<=8'h0A; lb_len<=7'd64;
                        send_line(T_HALT);
                    end
                end

                T_MBR_RD: begin
                    rd_lba   <= 32'd0;
                    rd_start <= 1'b1;
                    byte_cnt <= 10'd0;
                    if (rd_busy) tstate <= T_MBR_WAIT;
                end

                T_MBR_WAIT: begin
                    if (rd_done) begin
                        // latch partitions
                        for (i = 0; i < 4; i = i + 1) begin
                            p_type[i] <= mbr_buf[i*16 + 4];
                            p_lba[i]  <= {mbr_buf[i*16+11], mbr_buf[i*16+10],
                                          mbr_buf[i*16+9],  mbr_buf[i*16+8]};
                            p_sz[i]   <= {mbr_buf[i*16+15], mbr_buf[i*16+14],
                                          mbr_buf[i*16+13], mbr_buf[i*16+12]};
                        end
                        if ({mbr_sig0, mbr_sig1} == 16'h55AA) begin
                            // "MBR OK\n"
                            lb[0]<="M"; lb[1]<="B"; lb[2]<="R"; lb[3]<=" ";
                            lb[4]<="O"; lb[5]<="K"; lb[6]<=8'h0A;
                            lb_len<=7'd7; p_idx<=2'd0;
                            send_line(T_P_RPT);
                        end else begin
                            lb[0]<="M"; lb[1]<="B"; lb[2]<="R"; lb[3]<=" ";
                            lb[4]<="B"; lb[5]<="A"; lb[6]<="D"; lb[7]<=8'h0A;
                            lb_len<=7'd8;
                            send_line(T_HALT);
                        end
                    end else if (!rd_busy && rd_err != 4'd0) begin
                        err_show <= rd_err;
                        tstate   <= T_ERR_RPT;
                    end
                end

                // "Px T=tt L=llllllll S=ssssssss\n" for each of 4 entries
                T_P_RPT: begin
                    lb[0]<="P"; lb[1]<=8'h31+p_idx; lb[2]<=" ";
                    lb[3]<="T"; lb[4]<="="; p2h(5, p_type[p_idx]);
                    lb[7]<=" "; lb[8]<="L"; lb[9]<="=";
                    p8h(10, p_lba[p_idx]);
                    lb[18]<=" "; lb[19]<="S"; lb[20]<="=";
                    p8h(21, p_sz[p_idx]);
                    lb[29]<=8'h0A; lb_len<=7'd30;
                    if (p_idx == 2'd3) send_line(T_BPB_RD);
                    else begin
                        p_idx <= p_idx + 2'd1;
                        send_line(T_P_RPT);
                    end
                end

                T_BPB_RD: begin
                    if (p_type[0] == 8'd0) begin
                        lb[0]<="N"; lb[1]<="O"; lb[2]<="P"; lb[3]<=8'h0A;
                        lb_len<=7'd4;
                        send_line(T_HALT);
                    end else if (p_type[0] == 8'hEE) begin
                        // GPT protective MBR: follow to the GPT header
                        tstate <= T_GPT_RD;
                    end else begin
                        rd_lba   <= p_lba[0];
                        rd_start <= 1'b1;
                        byte_cnt <= 10'd0;
                        if (rd_busy) tstate <= T_BPB_WAIT;
                    end
                end

                T_BPB_WAIT: begin
                    if (rd_done) begin
                        bpb_bps    <= {16'd0, bpb[12], bpb[11]};
                        bpb_spc    <= bpb[13];
                        bpb_rsv    <= {16'd0, bpb[15], bpb[14]};
                        bpb_nf     <= bpb[16];
                        bpb_re     <= {16'd0, bpb[18], bpb[17]};
                        bpb_fatsz  <= (bpb[23] != 8'd0 || bpb[22] != 8'd0) ?
                                      {16'd0, bpb[23], bpb[22]} :
                                      {bpb[39], bpb[38], bpb[37], bpb[36]};
                        bpb_rootcl <= {bpb[47], bpb[46], bpb[45], bpb[44]};
                        is_fat32   <= ({bpb[18], bpb[17]} == 16'd0) &&
                                      ({bpb[23], bpb[22]} == 16'd0);
                        tstate     <= T_BPB_RPT;
                    end else if (!rd_busy && rd_err != 4'd0) begin
                        err_show <= rd_err;
                        tstate   <= T_ERR_RPT;
                    end
                end

                // "FS FAT16 BPS=512 SPC=08 NF=02 RE=0200 FSZ=000000E0\n"
                // "FS FAT32 BPS=512 SPC=08 NF=02 RC=00000002 FSZ=00000E40\n"
                T_BPB_RPT: begin
                    lb[0]<="F"; lb[1]<="S"; lb[2]<=" ";
                    if (is_fat32) begin
                        lb[3]<="F"; lb[4]<="A"; lb[5]<="T"; lb[6]<="3"; lb[7]<="2";
                        lb[8]<=" "; lb[9]<="B"; lb[10]<="P"; lb[11]<="S"; lb[12]<="=";
                        p8h(13, bpb_bps);
                        lb[21]<=" "; lb[22]<="S"; lb[23]<="P"; lb[24]<="C"; lb[25]<="=";
                        p2h(26, bpb_spc);
                        lb[28]<=" "; lb[29]<="N"; lb[30]<="F"; lb[31]<="=";
                        p2h(32, bpb_nf);
                        lb[34]<=" "; lb[35]<="R"; lb[36]<="C"; lb[37]<="=";
                        p8h(38, bpb_rootcl);
                        lb[46]<=" "; lb[47]<="F"; lb[48]<="S"; lb[49]<="Z"; lb[50]<="=";
                        p8h(51, bpb_fatsz);
                        lb[59]<=8'h0A; lb_len<=7'd60;
                    end else begin
                        lb[3]<="F"; lb[4]<="A"; lb[5]<="T"; lb[6]<="1"; lb[7]<="6";
                        lb[8]<=" "; lb[9]<="B"; lb[10]<="P"; lb[11]<="S"; lb[12]<="=";
                        p8h(13, bpb_bps);
                        lb[21]<=" "; lb[22]<="S"; lb[23]<="P"; lb[24]<="C"; lb[25]<="=";
                        p2h(26, bpb_spc);
                        lb[28]<=" "; lb[29]<="N"; lb[30]<="F"; lb[31]<="=";
                        p2h(32, bpb_nf);
                        lb[34]<=" "; lb[35]<="R"; lb[36]<="E"; lb[37]<="=";
                        p4h(38, bpb_re[15:0]);
                        lb[42]<=" "; lb[43]<="F"; lb[44]<="S"; lb[45]<="Z"; lb[46]<="=";
                        p8h(47, bpb_fatsz);
                        lb[55]<=8'h0A; lb_len<=7'd56;
                    end
                    // start fats*fatsz multiply
                    mul_acc <= 32'd0;
                    mul_n   <= bpb_nf;
                    send_line(T_FAT_MUL);
                end

                // compute data_lba pieces: mul_acc accumulates nf*fatsz
                T_FAT_MUL: begin
                    if (mul_n != 8'd0) begin
                        mul_acc <= mul_acc + bpb_fatsz;
                        mul_n   <= mul_n - 8'd1;
                    end else begin
                        // root_secs for FAT16 = re*32/512 = re>>4
                        root_secs <= is_fat32 ? 32'd0 : (bpb_re >> 4);
                        // root_lba = p1 + rsv + nf*fatsz (+ (rc-2)<<shift)
                        if (is_fat32)
                            root_lba <= p_lba[0] + bpb_rsv + mul_acc +
                                        ((bpb_rootcl - 32'd2) << spc_shift);
                        else
                            root_lba <= p_lba[0] + bpb_rsv + mul_acc;
                        data_lba <= p_lba[0] + bpb_rsv + mul_acc +
                                    (is_fat32 ? 32'd0 : (bpb_re >> 4));
                        // spc shift for later cluster math
                        case (bpb_spc)
                            8'd1:   spc_shift <= 5'd0;
                            8'd2:   spc_shift <= 5'd1;
                            8'd4:   spc_shift <= 5'd2;
                            8'd8:   spc_shift <= 5'd3;
                            8'd16:  spc_shift <= 5'd4;
                            8'd32:  spc_shift <= 5'd5;
                            8'd64:  spc_shift <= 5'd6;
                            default:spc_shift <= 5'd7;
                        endcase
                        scan_secs  <= 4'd0;
                        file_found <= 1'b0;
                        ent_valid  <= 1'b0;
                        ent_off    <= 5'd0;
                        tstate     <= T_ROOT_PRE;
                    end
                end

                T_ROOT_PRE: begin
                    // FAT32 root follows its cluster chain; scan up to 4
                    // sectors. FAT12/16 root is fixed-size (re*32/512).
                    if (is_fat32) scan_max <= 4'd4;
                    else if (root_secs > 32'd4) scan_max <= 4'd4;
                    else scan_max <= root_secs[3:0];
                    if (!is_fat32 && root_secs == 32'd0) begin
                        lb[0]<="R"; lb[1]<="T"; lb[2]<="0"; lb[3]<=8'h0A;
                        lb_len<=7'd4;
                        send_line(T_HALT);
                    end else begin
                        tstate <= T_ROOT_RD;
                    end
                end

                T_ROOT_RD: begin
                    if (scan_secs >= scan_max || file_found) begin
                        tstate <= T_FILE_RPT;
                    end else begin
                        rd_lba   <= root_lba + {28'd0, scan_secs};
                        rd_start <= 1'b1;
                        byte_cnt <= 10'd0;
                        ent_off  <= 5'd0;
                        ent_valid<= 1'b0;
                        if (rd_busy) tstate <= T_ROOT_WAIT;
                    end
                end

                T_ROOT_WAIT: begin
                    if (rd_done) begin
                        scan_secs <= scan_secs + 4'd1;
                        tstate    <= T_ROOT_RD;
                    end else if (!rd_busy && rd_err != 4'd0) begin
                        err_show <= rd_err;
                        tstate   <= T_ERR_RPT;
                    end
                end

                // "F0 <11-byte name> CL=xxxxxxxx SZ=xxxxxxxx\n" / "F0 NONE\n"
                T_FILE_RPT: begin
                    if (file_found) begin
                        lb[0]<="F"; lb[1]<="0"; lb[2]<=" ";
                        for (i = 0; i < 11; i = i + 1) lb[3+i] <= ent[i];
                        lb[14]<=" "; lb[15]<="C"; lb[16]<="L"; lb[17]<="=";
                        p8h(18, file_cl);
                        lb[26]<=" "; lb[27]<="S"; lb[28]<="Z"; lb[29]<="=";
                        p8h(30, file_sz);
                        lb[38]<=8'h0A; lb_len<=7'd39;
                        send_line(T_DATA_LBA);
                    end else begin
                        lb[0]<="F"; lb[1]<="0"; lb[2]<=" ";
                        lb[3]<="N"; lb[4]<="O"; lb[5]<="N"; lb[6]<="E"; lb[7]<=8'h0A;
                        lb_len<=7'd8;
                        send_line(T_HALT);
                    end
                end

                T_DATA_LBA: begin
                    data_lba <= data_lba + ((file_cl - 32'd2) << spc_shift);
                    tstate   <= T_DATA_RD;
                end

                T_DATA_RD: begin
                    rd_lba   <= data_lba;
                    rd_start <= 1'b1;
                    byte_cnt <= 10'd0;
                    if (rd_busy) tstate <= T_DATA_WAIT;
                end

                T_DATA_WAIT: begin
                    if (rd_done) begin
                        tstate <= T_DATA_RPT;
                    end else if (!rd_busy && rd_err != 4'd0) begin
                        err_show <= rd_err;
                        tstate   <= T_ERR_RPT;
                    end
                end

                // "D0: xx xx ... (32 bytes)\n"
                T_DATA_RPT: begin
                    lb[0]<="D"; lb[1]<="0"; lb[2]<=":"; lb[3]<=" ";
                    for (i = 0; i < 32; i = i + 1) begin
                        lb[4 + i*3]     <= hx(fdata[i][7:4]);
                        lb[4 + i*3 + 1] <= hx(fdata[i][3:0]);
                        lb[4 + i*3 + 2] <= 8'h20;
                    end
                    lb[100] <= 8'h0A;
                    lb_len  <= 7'd101;
                    send_line(T_DONE);
                end

                // -------- GPT follow path (protective MBR type 0xEE) --------
                T_GPT_RD: begin
                    rd_lba   <= 32'd1;
                    rd_start <= 1'b1;
                    byte_cnt <= 10'd0;
                    if (rd_busy) tstate <= T_GPT_WAIT;
                end

                T_GPT_WAIT: begin
                    if (rd_done) begin
                        gpt_elba <= {gbuf[16'h4B], gbuf[16'h4A],
                                     gbuf[16'h49], gbuf[16'h48]};
                        tstate   <= T_GPT_RPT;
                    end else if (!rd_busy && rd_err != 4'd0) begin
                        err_show <= rd_err;
                        tstate   <= T_ERR_RPT;
                    end
                end

                // "GP S=OK EL=xxxxxxxx\n" / "GP S=BAD\n"
                T_GPT_RPT: begin
                    lb[0]<="G"; lb[1]<="P"; lb[2]<=" "; lb[3]<="S"; lb[4]<="=";
                    if (gbuf[0]=="E" && gbuf[1]=="F" && gbuf[2]=="I" &&
                        gbuf[3]==" " && gbuf[4]=="P" && gbuf[5]=="A" &&
                        gbuf[6]=="R" && gbuf[7]=="T") begin
                        lb[5]<="O"; lb[6]<="K"; lb[7]<=" ";
                        lb[8]<="E"; lb[9]<="L"; lb[10]<="=";
                        p8h(11, gpt_elba);
                        lb[19]<=8'h0A; lb_len<=7'd20;
                        send_line(T_GE_RD);
                    end else begin
                        lb[5]<="B"; lb[6]<="A"; lb[7]<="D"; lb[8]<=8'h0A;
                        lb_len<=7'd9;
                        send_line(T_HALT);
                    end
                end

                T_GE_RD: begin
                    rd_lba   <= gpt_elba;
                    rd_start <= 1'b1;
                    byte_cnt <= 10'd0;
                    if (rd_busy) tstate <= T_GE_WAIT;
                end

                T_GE_WAIT: begin
                    if (rd_done) begin
                        // entry 0 first-LBA at offset 0x20
                        gpt_p1lba <= {gbuf[16'h23], gbuf[16'h22],
                                      gbuf[16'h21], gbuf[16'h20]};
                        tstate    <= T_GE_RPT;
                    end else if (!rd_busy && rd_err != 4'd0) begin
                        err_show <= rd_err;
                        tstate   <= T_ERR_RPT;
                    end
                end

                // "GP L=xxxxxxxx\n" then continue into the FAT flow
                T_GE_RPT: begin
                    if (gpt_p1lba != 32'd0) begin
                        lb[0]<="G"; lb[1]<="P"; lb[2]<=" "; lb[3]<="L";
                        lb[4]<="=";
                        p8h(5, gpt_p1lba);
                        lb[13]<=8'h0A; lb_len<=7'd14;
                        p_lba[0]  <= gpt_p1lba;
                        p_type[0] <= 8'h0C;   // treat as FAT partition
                        send_line(T_BPB_RD);
                    end else begin
                        lb[0]<="G"; lb[1]<="P"; lb[2]<=" "; lb[3]<="E";
                        lb[4]<="0"; lb[5]<=8'h0A; lb_len<=7'd6;
                        send_line(T_HALT);
                    end
                end

                T_DONE: begin
                    lb[0]<="S"; lb[1]<="D"; lb[2]<=" "; lb[3]<="O"; lb[4]<="K";
                    lb[5]<=8'h0A; lb_len<=7'd6;
                    send_line(T_HALT);
                end

                T_ERR_RPT: begin
                    lb[0]<="R"; lb[1]<="E"; lb[2]<="="; lb[3]<=hx(err_show);
                    lb[4]<=8'h0A; lb_len<=7'd5;
                    send_line(T_HALT);
                end

                T_LINE_WAIT: begin
                    if (!line_busy && !line_req) tstate <= after_line;
                end

                T_HALT: ;

                default: tstate <= T_HALT;
            endcase
        end
    end

endmodule
