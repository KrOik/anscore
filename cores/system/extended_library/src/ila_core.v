// ============================================================================
// ila_core -- wave2 idx31 "ILA": integrated logic analyser.
//
// 8 probe channels captured into a w2_dpram ring buffer (DEPTH = 1<<AW
// words x 8 bit, AW<=10).  Trigger condition:
//     match = (probe & trig_mask) == (trig_val & trig_mask)
//   trig_mode 0: level  (match while armed)
//   trig_mode 1: rising (match && !prev_match)
//   trig_mode 2: falling(!match &&  prev_match)
// Trigger is qualified only after >= pre_trig samples have been written
// (guarantees the pre-trigger window is populated).  After the trigger
// sample, DEPTH-pre_trig post samples are written (the trigger sample is
// post sample #1), then done asserts.  The capture window therefore ends
// DEPTH-pre_trig-1 samples after trig_ptr; trig_ptr is the buffer index of
// the trigger sample.
//
// Config register port (clk_en synchronous, accepted while !busy):
//   cfg_addr=0: trig_mask <= cfg_data[7:0]
//   cfg_addr=1: trig_val  <= cfg_data[7:0]
//   cfg_addr=2: pre_trig  <= cfg_data[AW-1:0]   (clamped to DEPTH-1)
//   cfg_addr=3: trig_mode <= cfg_data[1:0]
// arm = 1-beat pulse restarts a capture.  Readout port is a direct window
// on the buffer RAM read port (rd_en + rd_addr -> rd_q one beat later,
// holds while rd_en low).
//
// All registers clk_en gated (T2); buffer RAM goes through w2_dpram (T9).
// ============================================================================
module ila_core #(
    parameter AW = 10
)(
    input  wire           clk,
    input  wire           clk_en,
    input  wire           rst_n,

    input  wire [7:0]     probe,

    input  wire           cfg_we,
    input  wire [1:0]     cfg_addr,
    input  wire [15:0]    cfg_data,

    input  wire           arm,

    output reg            busy,
    output reg            done,
    output reg            fired,
    output reg  [AW-1:0]  trig_ptr,

    input  wire           rd_en,
    input  wire [AW-1:0]  rd_addr,
    output wire [7:0]     rd_q
);

localparam integer DEPTH = (1 << AW);
localparam S_IDLE = 2'd0;
localparam S_CAP  = 2'd1;

reg [1:0]    state;
reg [7:0]    trig_mask, trig_val;
reg [1:0]    trig_mode;
reg [AW-1:0] pre_trig;
reg [AW-1:0] ptr;
reg [AW:0]   samp_cnt;    // writes since arm (saturates at DEPTH)
reg [AW:0]   post_rem;   // post-trigger writes remaining
reg          prev_match;

wire [AW-1:0] pre_c   = (pre_trig > (DEPTH-1)) ? (DEPTH-1) : pre_trig;
wire [AW:0]   post_ln = DEPTH - {1'b0, pre_c};

wire match = ((probe & trig_mask) == (trig_val & trig_mask));
wire trig_cond = (trig_mode == 2'd0) ? match :
                 (trig_mode == 2'd1) ? ( match && !prev_match) :
                                       (!match &&  prev_match);

// capture write this beat (suppressed on the final beat once post_rem==0)
wire cap_we = (state == S_CAP) && (!fired || (post_rem != {AW+1{1'b0}}));

w2_dpram #(.W(8), .DEPTH(DEPTH), .AW(AW)) u_buf (
    .clk(clk), .clk_en(clk_en),
    .we(cap_we), .waddr(ptr), .wdata(probe),
    .re(rd_en), .raddr(rd_addr), .q(rd_q)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        trig_mask <= 8'h00; trig_val <= 8'h00; trig_mode <= 2'd0;
        pre_trig <= {AW{1'b0}};
        ptr <= {AW{1'b0}}; samp_cnt <= {(AW+1){1'b0}};
        post_rem <= {(AW+1){1'b0}}; prev_match <= 1'b0;
        busy <= 1'b0; done <= 1'b0; fired <= 1'b0; trig_ptr <= {AW{1'b0}};
    end else if (clk_en) begin
        if (cfg_we && !busy) begin
            case (cfg_addr)
                2'd0: trig_mask <= cfg_data[7:0];
                2'd1: trig_val  <= cfg_data[7:0];
                2'd2: pre_trig  <= cfg_data[AW-1:0];
                2'd3: trig_mode <= cfg_data[1:0];
                default: ;
            endcase
        end
        case (state)
            S_IDLE: begin
                if (arm) begin
                    state      <= S_CAP;
                    ptr        <= {AW{1'b0}};
                    samp_cnt   <= {(AW+1){1'b0}};
                    post_rem   <= {(AW+1){1'b0}};
                    prev_match <= 1'b0;
                    fired      <= 1'b0;
                    done       <= 1'b0;
                    busy       <= 1'b1;
                end
            end
            S_CAP: begin
                if (cap_we) begin
                    ptr <= ptr + {{(AW-1){1'b0}}, 1'b1};
                    if (samp_cnt < DEPTH[AW:0]) samp_cnt <= samp_cnt + {{AW{1'b0}},1'b1};
                    prev_match <= match;
                end
                if (!fired) begin
                    if (trig_cond && (samp_cnt >= {1'b0, pre_c})) begin
                        fired    <= 1'b1;
                        trig_ptr <= ptr;
                        post_rem <= post_ln - {{AW{1'b0}},1'b1};
                    end
                end else begin
                    if (post_rem == {(AW+1){1'b0}}) begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                        busy  <= 1'b0;
                    end else begin
                        post_rem <= post_rem - {{AW{1'b0}},1'b1};
                    end
                end
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
