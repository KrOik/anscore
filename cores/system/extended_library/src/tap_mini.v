// ============================================================================
// tap_mini -- tapeout-debug item A3: minimal JTAG TAP (IEEE 1149.1 subset).
//
// The dock cannot reach a real package TAP, so this models the TAP the ASIC
// is required to carry, driven by register bit-bang from the host (the same
// motion the B5 FT2232/JTAG driver performs on real silicon):
//
//   host writes {tms, tdi} then pulses `tck` -> one JTAG clock cycle.
//
// Instructions (4-bit IR):
//   BYPASS = 4'b1111   1-bit register                    (mandatory)
//   IDCODE = 4'b0001   32-bit device ID 32'h54414E47     (mandatory-ish)
//   SAMPLE = 4'b0100   64-bit capture of `sample_i`      (boundary sample)
//   SCAN   = 4'b0010   external scan chain bridge        (A1 access)
//
// SCAN is not a shift register inside the TAP: while IR=SCAN the tap drives
// scan_cap (in CAPTURE-DR), scan_shift+scan_si (in SHIFT-DR) and returns
// scan_so on TDO.  `sel_chain` is high while IR=SCAN so the top level can
// mux chain control between the register port and the TAP.
//
// All state advances on `tck` pulses inside the system clock domain; TDO is
// combinational on the current DR LSB (valid to read after a shift pulse).
// ============================================================================
module tap_mini (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tck,        // 1-beat pulse: one JTAG clock
    input  wire        tms,
    input  wire        tdi,
    input  wire [63:0] sample_i,   // boundary/status vector for SAMPLE
    // scan-chain bridge (IR=SCAN)
    input  wire        scan_so,
    output reg         scan_cap,
    output reg         scan_shift,
    output wire        scan_si,
    output wire        sel_chain,
    output wire        tdo,
    output reg  [3:0]  state,
    output reg  [3:0]  ir
);

// TAP states
localparam S_TLR   = 4'd0;
localparam S_RTI   = 4'd1;
localparam S_SDR   = 4'd2;   // select-DR-scan
localparam S_CDR   = 4'd3;   // capture-DR
localparam S_SHDR  = 4'd4;   // shift-DR
localparam S_E1DR  = 4'd5;
localparam S_PDR   = 4'd6;   // pause-DR
localparam S_E2DR  = 4'd7;
localparam S_UDR   = 4'd8;   // update-DR
localparam S_SIR   = 4'd9;   // select-IR-scan
localparam S_CIR   = 4'd10;  // capture-IR
localparam S_SHIR  = 4'd11;  // shift-IR
localparam S_E1IR  = 4'd12;
localparam S_PIR   = 4'd13;
localparam S_E2IR  = 4'd14;
localparam S_UIR   = 4'd15;  // update-IR

localparam IR_BYPASS = 4'b1111;
localparam IR_IDCODE = 4'b0001;
localparam IR_SCAN   = 4'b0010;
localparam IR_SAMPLE = 4'b0100;

localparam [31:0] IDCODE = 32'h54414E47;   // "TANG", LSB=1 per spec

reg        byp_r;
reg [31:0] idr;
reg [63:0] sdr;
reg [3:0]  ir_sr;

// next-state function (standard TAP transitions on TCK rising)
function [3:0] nxt;
    input [3:0] s;
    input       m;
    begin
        case (s)
            S_TLR:  nxt = m ? S_TLR  : S_RTI;
            S_RTI:  nxt = m ? S_SDR  : S_RTI;
            S_SDR:  nxt = m ? S_SIR  : S_CDR;
            S_CDR:  nxt = m ? S_E1DR : S_SHDR;
            S_SHDR: nxt = m ? S_E1DR : S_SHDR;
            S_E1DR: nxt = m ? S_UDR  : S_PDR;
            S_PDR:  nxt = m ? S_E2DR : S_PDR;
            S_E2DR: nxt = m ? S_UDR  : S_SHDR;
            S_UDR:  nxt = m ? S_SDR  : S_RTI;
            S_SIR:  nxt = m ? S_TLR  : S_CIR;
            S_CIR:  nxt = m ? S_E1IR : S_SHIR;
            S_SHIR: nxt = m ? S_E1IR : S_SHIR;
            S_E1IR: nxt = m ? S_UIR  : S_PIR;
            S_PIR:  nxt = m ? S_E2IR : S_PIR;
            S_E2IR: nxt = m ? S_UIR  : S_SHIR;
            S_UIR:  nxt = m ? S_SDR  : S_RTI;
            default: nxt = S_TLR;
        endcase
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= S_TLR;
        ir         <= IR_IDCODE;
        ir_sr      <= 4'd0;
        byp_r      <= 1'b0;
        idr        <= 32'd0;
        sdr        <= 64'd0;
        scan_cap   <= 1'b0;
        scan_shift <= 1'b0;
    end else begin
        scan_cap   <= 1'b0;
        scan_shift <= 1'b0;
        if (tck) begin
            state <= nxt(state, tms);
            case (state)
                S_CDR: begin
                    case (ir)
                        IR_IDCODE: idr <= IDCODE;
                        IR_SAMPLE: sdr <= sample_i;
                        IR_SCAN:   scan_cap <= 1'b1;
                        default:   byp_r <= 1'b0;
                    endcase
                end
                S_SHDR: begin
                    case (ir)
                        IR_IDCODE: idr <= {tdi, idr[31:1]};
                        IR_SAMPLE: sdr <= {tdi, sdr[63:1]};
                        IR_SCAN:   scan_shift <= 1'b1;
                        default:   byp_r <= tdi;
                    endcase
                end
                S_CIR:  ir_sr <= 4'b0101;              // mandatory pattern
                S_SHIR: ir_sr <= {tdi, ir_sr[3:1]};
                S_UIR:  ir    <= ir_sr;
                default: ;
            endcase
        end
    end
end

assign scan_si   = tdi;
assign sel_chain = (ir == IR_SCAN);
assign tdo       = (state == S_SHDR) ?
                       ((ir == IR_IDCODE) ? idr[0] :
                        (ir == IR_SAMPLE) ? sdr[0] :
                        (ir == IR_SCAN)   ? scan_so : byp_r) :
                   (state == S_SHIR) ? ir_sr[0] : 1'b0;

endmodule
