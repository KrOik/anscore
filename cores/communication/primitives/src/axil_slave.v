// AXI4-Lite slave: 16 x 32-bit register bank, full handshakes on all five
// channels, independent AW/W capture (either order accepted), SLVERR decode
// on out-of-range or unaligned addresses. Byte address map: 0x00..0x3F.
// All internal state is gated by clk_en.
module axil_slave (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clk_en,
    // write address channel
    input  wire        awvalid,
    output reg         awready,
    input  wire [7:0]  awaddr,
    // write data channel
    input  wire        wvalid,
    output reg         wready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    // write response channel
    output reg         bvalid,
    input  wire        bready,
    output reg  [1:0]  bresp,
    // read address channel
    input  wire        arvalid,
    output reg         arready,
    input  wire [7:0]  araddr,
    // read data channel
    output reg         rvalid,
    input  wire        rready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp
);

localparam [1:0] RESP_OKAY   = 2'b00;
localparam [1:0] RESP_SLVERR = 2'b10;

reg [31:0] regs [0:15];
reg [7:0]  aw_hold;
reg        aw_pend;             // awaddr captured, awaiting wdata
reg [31:0] w_hold;
reg [3:0]  wstrb_hold;
reg        w_pend;              // wdata captured, awaiting awaddr

wire aw_ok   = (aw_hold[7:6] == 2'b00) && (aw_hold[1:0] == 2'b00);
wire awok_in = (awaddr[7:6]  == 2'b00) && (awaddr[1:0]  == 2'b00);
wire arok_in = (araddr[7:6]  == 2'b00) && (araddr[1:0]  == 2'b00);

// combined write commit: fires the cycle both halves are present
wire aw_hs = awvalid && awready;
wire w_hs  = wvalid  && wready;
wire wr_commit = (aw_pend || aw_hs) && (w_pend || w_hs);
wire [7:0]  wr_addr  = aw_pend ? aw_hold   : awaddr;
wire        wr_ok    = aw_pend ? aw_ok     : awok_in;
wire [31:0] wr_data  = w_pend  ? w_hold    : wdata;
wire [3:0]  wr_strb  = w_pend  ? wstrb_hold: wstrb;

integer ri;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        awready <= 1'b0;
        wready  <= 1'b0;
        bvalid  <= 1'b0;
        bresp   <= RESP_OKAY;
        arready <= 1'b0;
        rvalid  <= 1'b0;
        rdata   <= 32'd0;
        rresp   <= RESP_OKAY;
        aw_hold <= 8'd0;
        aw_pend <= 1'b0;
        w_hold  <= 32'd0;
        wstrb_hold <= 4'd0;
        w_pend  <= 1'b0;
        for (ri = 0; ri < 16; ri = ri + 1) regs[ri] <= 32'd0;
    end else if (clk_en) begin
        // ------------------------------------------------ write channels
        // aw: armed when nothing pending and no response in flight
        if (aw_hs) begin
            aw_hold <= awaddr;
            aw_pend <= 1'b1;
            awready <= 1'b0;
        end else if (!aw_pend && !bvalid) begin
            awready <= 1'b1;
        end else begin
            awready <= 1'b0;
        end

        // w: armed when nothing pending and no response in flight
        if (w_hs) begin
            w_hold     <= wdata;
            wstrb_hold <= wstrb;
            w_pend     <= 1'b1;
            wready     <= 1'b0;
        end else if (!w_pend && !bvalid) begin
            wready <= 1'b1;
        end else begin
            wready <= 1'b0;
        end

        if (wr_commit) begin
            aw_pend <= 1'b0;
            w_pend  <= 1'b0;
            if (wr_ok) begin
                if (wr_strb[0]) regs[wr_addr[5:2]][7:0]   <= wr_data[7:0];
                if (wr_strb[1]) regs[wr_addr[5:2]][15:8]  <= wr_data[15:8];
                if (wr_strb[2]) regs[wr_addr[5:2]][23:16] <= wr_data[23:16];
                if (wr_strb[3]) regs[wr_addr[5:2]][31:24] <= wr_data[31:24];
                bresp <= RESP_OKAY;
            end else begin
                bresp <= RESP_SLVERR;
            end
            bvalid <= 1'b1;
        end else if (bvalid && bready) begin
            bvalid <= 1'b0;
        end

        // ------------------------------------------------ read channels
        if (rvalid && rready) begin
            rvalid  <= 1'b0;
            arready <= 1'b1;
        end else if (arready && arvalid) begin
            arready <= 1'b0;
            rvalid  <= 1'b1;
            rdata   <= arok_in ? regs[araddr[5:2]] : 32'd0;
            rresp   <= arok_in ? RESP_OKAY : RESP_SLVERR;
        end else if (!rvalid) begin
            arready <= 1'b1;
        end
    end
end

endmodule
