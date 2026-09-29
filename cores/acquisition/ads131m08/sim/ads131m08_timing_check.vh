// ADS131M08 SPI timing compliance monitor, included by testbenches.
//
// Limits come from TI SBAS950B section 6.6 for 2.7 V <= DVDD <= 3.6 V.  Every
// parameter is measured on the real pads rather than inferred from RTL state,
// and every parameter counts how many times it was sampled, so a testbench
// cannot pass this vacuously by never exercising the bus.
//
// REQUIREMENTS ON THE INCLUDING MODULE
//   * integer ``errors`` must already be declared before this include, because
//     Verilog cannot reference a module-level variable from a task that appears
//     earlier in the file;
//   * the pads must be named ``adc_sclk``, ``adc_din``, ``adc_dout``,
//     ``adc_cs_n``.
//
// After the stimulus, call ``timing_report`` and then
// ``timing_check_observed`` (the latter fails if the bus never ran).
`timescale 1ns/1ps

    localparam integer T_SCL_MIN  = 20, // tw(SCL)  SCLK low
                       T_SCH_MIN  = 20, // tw(SCH)  SCLK high
                       T_SC_MIN   = 40, // tc(SC)   SCLK period
                       T_CSSC_MIN = 16, // td(CSSC) CS falling -> first SCLK rising
                       T_SCCS_MIN = 10, // td(SCCS) last SCLK falling -> CS rising
                       T_CSH_MIN  = 15, // tw(CSH)  CS high
                       T_SUDI_MIN = 5,  // tsu(DI)  DIN setup before SCLK falling
                       T_HDI_MIN  = 10; // th(DI)   DIN hold after SCLK falling

    localparam integer P_SCL = 0, P_SCH = 1, P_SC = 2, P_CSSC = 3,
                       P_SCCS = 4, P_CSH = 5, P_SUDI = 6, P_HDI = 7;

    time    t_sclk_r = 0, t_sclk_f = 0, t_cs_f = 0, t_cs_r = 0, t_din = 0;
    integer sclk_rises_in_frame = 0;
    reg     cs_active = 0;

    integer   tmin [0:7];
    integer   tcnt [0:7];

    integer   tc_i;
    initial begin
        tmin[P_SCL]=999999; tmin[P_SCH]=999999; tmin[P_SC]=999999;
        tmin[P_CSSC]=999999; tmin[P_SCCS]=999999; tmin[P_CSH]=999999;
        tmin[P_SUDI]=999999; tmin[P_HDI]=999999;
        for (tc_i = 0; tc_i < 8; tc_i = tc_i + 1) tcnt[tc_i] = 0;
    end

    task tcheck(input integer id, input integer meas, input integer limit,
                input [255:0] what);
        begin
            tcnt[id] = tcnt[id] + 1;
            if (meas < tmin[id]) tmin[id] = meas;
            if (meas < limit) begin
                errors = errors + 1;
                $display("  FAIL timing: %0s = %0d ns < %0d ns", what, meas, limit);
            end
        end
    endtask

    always @(negedge adc_cs_n) begin
        cs_active = 1;
        sclk_rises_in_frame = 0;
        t_cs_f = $time;
        if (t_cs_r != 0) tcheck(P_CSH,  $time - t_cs_r, T_CSH_MIN, "tw(CSH) CS high");
    end

    always @(posedge adc_cs_n) begin
        if (cs_active && t_sclk_f != 0)
            tcheck(P_SCCS, $time - t_sclk_f, T_SCCS_MIN,
                   "td(SCCS) last SCLK fall -> CS high");
        cs_active = 0;
        t_cs_r = $time;
    end

    always @(posedge adc_sclk) begin
        if (sclk_rises_in_frame == 0)
            tcheck(P_CSSC, $time - t_cs_f, T_CSSC_MIN,
                   "td(CSSC) CS low -> first SCLK rise");
        if (t_sclk_r != 0) tcheck(P_SC,  $time - t_sclk_r, T_SC_MIN, "tc(SC) SCLK period");
        if (t_sclk_f != 0) tcheck(P_SCL, $time - t_sclk_f, T_SCL_MIN, "tw(SCL) SCLK low");
        sclk_rises_in_frame = sclk_rises_in_frame + 1;
        t_sclk_r = $time;
    end

    always @(negedge adc_sclk) begin
        if (cs_active && t_sclk_r != 0)
            tcheck(P_SCH,  $time - t_sclk_r, T_SCH_MIN, "tw(SCH) SCLK high");
        if (t_din != 0)
            tcheck(P_SUDI, $time - t_din,    T_SUDI_MIN, "tsu(DI) DIN setup");
        if (cs_active) t_sclk_f = $time;
    end

    always @(adc_din) begin
        if (cs_active && t_sclk_f != 0)
            tcheck(P_HDI, $time - t_sclk_f, T_HDI_MIN, "th(DI) DIN hold");
        t_din = $time;
    end

    task timing_report;
        begin
            $display("  timing margins (ns), measured/limit:");
            $display("    tw(SCL)  %0d/%0d  n=%0d", tmin[P_SCL],  T_SCL_MIN,  tcnt[P_SCL]);
            $display("    tw(SCH)  %0d/%0d  n=%0d", tmin[P_SCH],  T_SCH_MIN,  tcnt[P_SCH]);
            $display("    tc(SC)   %0d/%0d  n=%0d", tmin[P_SC],   T_SC_MIN,   tcnt[P_SC]);
            $display("    td(CSSC) %0d/%0d  n=%0d", tmin[P_CSSC], T_CSSC_MIN, tcnt[P_CSSC]);
            $display("    td(SCCS) %0d/%0d  n=%0d", tmin[P_SCCS], T_SCCS_MIN, tcnt[P_SCCS]);
            $display("    tw(CSH)  %0d/%0d  n=%0d", tmin[P_CSH],  T_CSH_MIN,  tcnt[P_CSH]);
            $display("    tsu(DI)  %0d/%0d  n=%0d", tmin[P_SUDI], T_SUDI_MIN, tcnt[P_SUDI]);
            $display("    th(DI)   %0d/%0d  n=%0d", tmin[P_HDI],  T_HDI_MIN,  tcnt[P_HDI]);
        end
    endtask

    task timing_check_observed;
        begin
            if (tcnt[P_CSSC] == 0 || tcnt[P_SUDI] == 0 || tcnt[P_HDI] == 0 ||
                tcnt[P_SCCS] == 0) begin
                errors = errors + 1;
                $display("  FAIL timing: monitor never observed traffic");
            end
        end
    endtask
