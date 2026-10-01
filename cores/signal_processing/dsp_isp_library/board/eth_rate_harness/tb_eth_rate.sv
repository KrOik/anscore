// End-to-end Ethernet testbench for eth_rate_harness.
//
// The DUT sits behind rmii_eth_pipe, so stimulus is a raw RMII octet stream
// (preamble, SFD, Ethernet/IPv4/UDP frame, FCS) written by run_eth.py, and the
// expected result is the octet stream the DUT puts on rmii_txd/rmii_txen.  Both
// sides are recorded as hex bytes; all protocol parsing, CRC checking and
// numerical verification happens in Python against the independent model, so
// this file contains no expectations of its own.
`timescale 1ns/1ps

module tb_eth_rate;
parameter CORE = 0;

reg clk27 = 0;
always #18.5 clk27 = ~clk27;
reg clk50 = 0;
always #10 clk50 = ~clk50;

// Pin polarity as on the board: the key pulls the pin to GND, the pull-up keeps
// it HIGH when released, and HIGH is the running level.  It starts LOW here to
// stand in for the clear-on-configure state hardware gives every register.
reg        btn = 1'b0;
reg        rmii_crs = 0;
reg [1:0]  rmii_rxd = 0;
wire [1:0] rmii_txd;
wire       rmii_txen, rmii_mdc, rmii_mdio, rmii_phyrst;
wire [5:0] led;

eth_rate_harness #(.CORE(CORE)) dut (
    .clk(clk27), .rst(btn),
    .netrmii_clk50m(clk50), .netrmii_rx_crs(rmii_crs), .netrmii_rxd(rmii_rxd),
    .netrmii_mdc(rmii_mdc), .netrmii_txen(rmii_txen), .netrmii_mdio(rmii_mdio),
    .netrmii_txd(rmii_txd), .phyrst(rmii_phyrst), .led(led));

integer stim_f = 0, trace_f = 0, got = 0, want = 0, octets_in = 0,
          expect_total = 0, n = 0, i = 0;
integer byte_pulses = 0, rx_pulses = 0, end_pulses = 0, txen_pulses = 0;
reg [7:0] octets [0:4095];
reg [127:0] stim_name, trace_name;

// One octet per four RMII cycles, LSB pair first, exactly as RMII defines it.
// crs_dv and the first pair must appear in the SAME cycle (that is how the PHY
// presents RXDV) and the idle pair level is 2'b11, so this drives on posedge
// with non-blocking assignments like the proven pipe-level testbench does.
task drive_octet(input [7:0] b);
begin
    @(posedge clk50); rmii_crs <= 1'b1; rmii_rxd <= b[1:0];
    @(posedge clk50);                    rmii_rxd <= b[3:2];
    @(posedge clk50);                    rmii_rxd <= b[5:4];
    @(posedge clk50);                    rmii_rxd <= b[7:6];
end
endtask

task send_octets(input integer count);
    integer k;
begin
    rmii_crs <= 1'b0; rmii_rxd <= 2'b11;
    @(posedge clk50); @(posedge clk50);
    $display("TX start t=%0t octets=%0d", $time, count); $fflush();
    for (k = 0; k < count; k = k + 1) drive_octet(octets[k]);
    @(posedge clk50); rmii_crs <= 1'b0; rmii_rxd <= 2'b11;
    $display("TX done t=%0t got=%0d", $time, got); $fflush();
    repeat(12) @(posedge clk50);
end
endtask

always @(posedge dut.pipe.rx_byte_valid) byte_pulses = byte_pulses + 1;
always @(posedge dut.rx_valid) rx_pulses = rx_pulses + 1;
always @(posedge dut.rx_end) end_pulses = end_pulses + 1;
always @(posedge rmii_txen) txen_pulses = txen_pulses + 1;

// Reassemble whatever the DUT transmits: four 2-bit pairs per octet.  Each
// txen-high period is one Ethernet frame, and its octet count is written to
// <trace>.len so the host parser can delimit frames from the carrier instead
// of guessing where 0xD5 happens to appear inside a payload.
integer rx_pairs = 0, tx_pairs = 0, len_f = 0;
reg txen_q = 1'b0;
reg [7:0] rx_acc = 0;
reg [8*80:1] len_name;
always @(posedge clk50) begin
    if (rmii_txen) begin
        tx_pairs = tx_pairs + 1;
        rx_acc   = {rmii_txd, rx_acc[7:2]};
        rx_pairs = rx_pairs + 1;
        if (rx_pairs == 4) begin
            rx_pairs = 0;
            $fwrite(trace_f, "%02x\n", rx_acc);
            $fflush(trace_f);
            got = got + 1;
        end
    end else begin
        rx_pairs = 0;
        // txen_q still holds the PREVIOUS cycle's carrier level here, which is
        // exactly the rising-to-falling transition that closes a frame.
        if (txen_q) begin
            if (tx_pairs % 4 != 0) $display("WARN partial-octet t=%0t pairs=%0d",
                                            $time, tx_pairs);
            $fwrite(len_f, "%0d\n", tx_pairs / 4);
            $fflush(len_f);
            tx_pairs = 0;
        end
    end
    txen_q = rmii_txen;
end

initial begin
    if (!$value$plusargs("stim=%s", stim_name)) $fatal(1, "no +stim");
    if (!$value$plusargs("trace=%s", trace_name)) $fatal(1, "no +trace");
    if (!$value$plusargs("len=%s", len_name)) $fatal(1, "no +len");
    stim_f  = $fopen(stim_name, "r");
    trace_f = $fopen(trace_name, "w");
    len_f   = $fopen(len_name, "w");
    if (stim_f == 0 || trace_f == 0 || len_f == 0) $fatal(1, "file open");
    // The key pulls its pin to GND and the pull-up keeps it HIGH when released,
    // so it starts LOW: that holds the pipe's rst_n low long enough for its RX
    // parser registers to take real values, the way configure-time clears do on
    // hardware.
    repeat (200) @(negedge clk50);
    // PHY/SMI bring-up (MDIO page writes, BSR link poll) belongs to the
    // pipe-level testbench; here the link is declared up so this test exercises
    // the block contract, not the MDIO master.
    force dut.pipe.phy_rdy = 1'b1;
    @(negedge clk50);
    btn = 1'b1;             // release the key; HIGH is the running level
    // The harness releases itself ~4096 clk50 cycles after the link comes up;
    // a frame sent before that is simply lost, so wait for the real reset edge.
    wait (dut.rst_n === 1'b1);
    repeat (50) @(negedge clk50);
    $display("link up, reset done state=%0d t=%0t", dut.state, $time);
    $fflush();

    while (!$feof(stim_f)) begin
        n = $fscanf(stim_f, "%d %d\n", octets_in, want);
        if (n == 2) begin
            for (i = 0; i < octets_in; i = i + 1)
                if ($fscanf(stim_f, "%h\n", octets[i]) != 1) $fatal(1, "stim octet");
            expect_total = expect_total + want;
            send_octets(octets_in);
            if (want == 0) begin
                // A request the harness must NOT answer: its in-payload CRC-32
                // trailer is wrong, so TRAIL drops it.  There is no reply to
                // wait for, so wait a bounded window instead -- long enough
                // that an illegal reply would have been counted in `got` and
                // seen by the host as one datagram too many.
                repeat (20000) @(negedge clk50);
                $display("silent packet sent=%0d got=%0d state=%0d t=%0t",
                         octets_in, got, dut.state, $time);
            end else begin
                wait (got >= expect_total);
            end
            $display("packet sent=%0d reply_octets=%0d target=%0d state=%0d in=%0d out=%0d time=%0t",
                     octets_in, got, expect_total, dut.state, dut.input_count,
                     dut.output_count, $time);
            $fflush();
            repeat (200) @(negedge clk50);
        end
    end
    $display("PASS ETH-E2E core=%0d octets=%0d", CORE, got);
    $fclose(trace_f);
    $fclose(len_f);
    $finish;
end

initial begin
    #2_000_000_000;
    $display("FATAL timeout state=%0d got=%0d expect=%0d flags=%0b",
             dut.state, got, expect_total, dut.flags);
    $fatal(1, "timeout");
end

initial forever begin
    #3_000_000;
    $display("checkpoint t=%0t crs=%b rxd=%b rst50=%b txen=%b state=%0d index=%0d count=%0d rx_v=%b byte_v=%b udp_ok=%b seen=%b csum=%b local=%b len=%0d tx_busy=%b grant=%b got=%0d phy=%b bytes=%0d rxp=%0d endp=%0d txenp=%0d",
             $time, rmii_crs, rmii_rxd, dut.pipe.rst50, rmii_txen, dut.state, dut.index, dut.count, dut.rx_valid,
             dut.pipe.rx_byte_valid, dut.pipe.udp_ok, dut.pipe.udp_seen,
             dut.pipe.ip_csum_ok, dut.pipe.dest_local, dut.pipe.rx_pay_count,
             dut.tx_busy, dut.pipe.tx_grant, got, dut.phy_ready, byte_pulses, rx_pulses, end_pulses, txen_pulses);
    $fflush();
end

always @(posedge clk50) if (dut.state === 4'bxxxx) $fatal(1, "state x");
endmodule
