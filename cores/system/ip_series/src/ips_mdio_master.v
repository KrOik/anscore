`timescale 1ns / 1ps
// ips_mdio_master : IEEE 802.3 Clause 22 MDIO (management) master.
//
// Contract (docs/IP_CORE_SOP.md: clk_en gates every register, rst_n is the
// active-low asynchronous reset):
//   * mdio is the physical bidirectional pin and is open drain: the core only
//     ever sinks it (o_lo) or releases it, so a pull-up reads back as a 1.
//     mdc is produced by the core from the explicit tick input: tick is a
//     one-cycle enable that arrives once per MDC half-period, so the Python
//     model can reproduce every transition cycle exactly.
//   * Frame layout, MSB first, one bit-time per MDC period:
//       PRE_BITS ones (preamble, released line), ST = 01,
//       OP = OP_RD (01) for a read and OP_WR (10) for a write,
//       PA = phy_addr[4:0], TA = turnaround, then DATA_BITS data bits.
//     o_cmd holds {ST, OP, PA} of the frame that was last launched; o_bc counts
//     bit-times inside the current field and o_pos over the whole frame.
//   * Drive is presented on the rising tick of mdc and the line is sampled on
//     the falling tick, i.e. MDIO changes with MDC rising and is captured with
//     MDC falling, as the clause requires.
//   * Turnaround: the first turnaround bit-time is always released (the Z bit).
//     In the second one a write master sinks the line itself, while a read
//     master releases it and waits for the PHY to pull it low.  Every wait
//     bit-time that finds the line still high increments o_waits; after
//     TMO_LIMIT turnaround bit-times the read is aborted, o_err_to increments
//     (sticky) and the frame ends without a data phase.
//   * After the data phase one bit-time is spent with the line released before
//     the core returns to idle, so the bus is handed back tri-state.
//   * start is ignored while a frame is in progress; o_rdata holds the last
//     DATA_BITS sampled bits and o_sh is the live transmit shifter.
module ips_mdio_master #(
    parameter PRE_BITS  = 32,
    parameter TMO_LIMIT = 3,
    parameter DATA_BITS = 16
)(
    input  wire                 clk,
    input  wire                 clk_en,
    input  wire                 rst_n,
    input  wire                 tick,
    input  wire                 start,
    input  wire                 rnw,
    input  wire [4:0]           phy_addr,
    input  wire [DATA_BITS-1:0] wdata,
    inout  wire                 mdio,
    output reg                  mdc,
    output reg [2:0]            o_state,
    output reg [5:0]            o_bc,
    output reg [6:0]            o_pos,
    output reg [2:0]            o_waits,
    output reg [DATA_BITS-1:0]  o_rdata,
    output reg [DATA_BITS-1:0]  o_sh,
    output reg [8:0]            o_cmd,
    output reg [7:0]            o_txn,
    output reg [3:0]            o_err_to,
    output reg                  o_own,
    output reg                  o_busy,
    output reg                  o_lo
);

localparam [1:0] OP_RD  = 2'b01;
localparam [1:0] OP_WR  = 2'b10;
localparam [1:0] ST_FLD = 2'b01;

localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_PRE  = 3'd1;
localparam [2:0] S_ST   = 3'd2;
localparam [2:0] S_OP   = 3'd3;
localparam [2:0] S_PA   = 3'd4;
localparam [2:0] S_TA   = 3'd5;
localparam [2:0] S_DAT  = 3'd6;
localparam [2:0] S_END  = 3'd7;

reg              rnw_l;
reg [5:0]        ta_cnt;
reg [8:0]        ash;

wire [1:0] op_bits  = rnw ? OP_RD : OP_WR;
wire [8:0] cmd_init = {ST_FLD, op_bits, phy_addr};
wire       is_wr    = ~rnw_l;

assign mdio = o_lo ? 1'b0 : 1'bz;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mdc      <= 1'b0;
        o_state  <= S_IDLE;
        o_bc     <= 6'd0;
        o_pos    <= 7'd0;
        o_waits  <= 3'd0;
        o_rdata  <= {DATA_BITS{1'b0}};
        o_sh     <= {DATA_BITS{1'b0}};
        ash      <= 9'h1FF;
        o_cmd    <= 9'h1FF;
        o_txn    <= 8'h00;
        o_err_to <= 4'h0;
        o_own    <= 1'b0;
        o_busy   <= 1'b0;
        o_lo     <= 1'b0;
        rnw_l    <= 1'b0;
        ta_cnt   <= 6'd0;
    end else if (clk_en) begin
        if (start && !o_busy) begin
            o_state <= S_PRE;
            o_bc    <= 6'd0;
            o_pos   <= 7'd0;
            o_waits <= 3'd0;
            ta_cnt  <= 6'd0;
            ash     <= cmd_init;
            o_cmd   <= cmd_init;
            o_sh    <= wdata;
            o_rdata <= {DATA_BITS{1'b0}};
            o_own   <= 1'b0;
            o_lo    <= 1'b0;
            o_busy  <= 1'b1;
            rnw_l   <= rnw;
        end
        else if (o_busy && tick) begin
            if (!mdc) begin
                // rising tick: present this bit-time's drive
                mdc <= 1'b1;
                case (o_state)
                    S_PRE: begin
                        o_own <= 1'b1;
                        o_lo  <= 1'b0;
                    end
                    S_ST, S_OP, S_PA: begin
                        o_own <= 1'b1;
                        o_lo  <= ~ash[8];
                        ash   <= {ash[7:0], 1'b1};
                    end
                    S_TA: begin
                        o_own <= ~rnw_l;
                        o_lo  <= is_wr & (ta_cnt != 6'd0);
                    end
                    S_DAT: begin
                        o_own <= ~is_wr;
                        o_lo  <= is_wr & ~o_sh[DATA_BITS-1];
                        o_sh  <= {o_sh[DATA_BITS-2:0], 1'b1};
                    end
                    default: begin
                        o_own <= 1'b0;
                        o_lo  <= 1'b0;
                    end
                endcase
            end
            else begin
                // falling tick: capture the line and advance the frame
                mdc   <= 1'b0;
                o_pos <= o_pos + 7'd1;
                if (o_state != S_END) begin
                    o_rdata <= {o_rdata[DATA_BITS-2:0], mdio};
                end
                case (o_state)
                    S_PRE: begin
                        if (o_bc == (PRE_BITS - 1)) begin
                            o_bc    <= 6'd0;
                            o_state <= S_ST;
                        end
                        else begin
                            o_bc <= o_bc + 6'd1;
                        end
                    end
                    S_ST: begin
                        o_bc <= o_bc + 6'd1;
                        if (o_bc == 6'd1) begin
                            o_bc    <= 6'd0;
                            o_state <= S_OP;
                        end
                    end
                    S_OP: begin
                        o_bc <= o_bc + 6'd1;
                        if (o_bc == 6'd1) begin
                            o_bc    <= 6'd0;
                            o_state <= S_PA;
                        end
                    end
                    S_PA: begin
                        o_bc <= o_bc + 6'd1;
                        if (o_bc == 6'd4) begin
                            o_bc    <= 6'd0;
                            o_state <= S_TA;
                        end
                    end
                    S_TA: begin
                        ta_cnt <= ta_cnt + 6'd1;
                        if (ta_cnt == 6'd0) begin
                            o_bc <= 6'd0;
                        end
                        else if (!mdio) begin
                            o_bc    <= 6'd0;
                            o_state <= S_DAT;
                        end
                        else if (ta_cnt >= TMO_LIMIT) begin
                            o_err_to <= o_err_to + 4'd1;
                            o_bc     <= 6'd0;
                            o_state  <= S_END;
                        end
                        else begin
                            o_waits <= o_waits + 3'd1;
                            o_bc    <= o_bc + 6'd1;
                        end
                    end
                    S_DAT: begin
                        o_bc <= o_bc + 6'd1;
                        if (o_bc == (DATA_BITS - 1)) begin
                            o_bc    <= 6'd0;
                            o_state <= S_END;
                        end
                    end
                    default: begin
                        o_state <= S_IDLE;
                        o_busy  <= 1'b0;
                        o_own   <= 1'b0;
                        o_lo    <= 1'b0;
                        o_txn   <= o_txn + 8'd1;
                    end
                endcase
            end
        end
    end
end

endmodule
