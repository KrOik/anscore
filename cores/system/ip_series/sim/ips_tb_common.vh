// Shared testbench helpers for the ip_series_20k production line.
//
// Include this once inside a testbench module scope, after `timescale:
//     `include "ips_tb_common.vh"
// The gate always compiles with -I sim, so the include resolves from any cwd.
//
// Contract enforced by scripts/ip_series_harness.ps1:
//   - fold every observed output word with ips_fnv_word(), MSB byte first
//   - increment ips_cycle once per enabled clock edge
//   - call ips_verdict(1'b1) / ips_verdict(1'b1'b0) exactly once at the end;
//     it prints  VERDICT <core> PASS|FAIL D=<8 hex> C=<cycles>  and $fatal on
//     failure so a failing core can never look like a green run.
//
// The FNV constant multiply lives only in the testbench.  Synthesis tops the
// core module, so docs/IP_CORE_SOP.md trap T4 (constant multiplies eating DSPs)
// does not apply here.

reg ips_clk = 1'b0;
always #5 ips_clk = ~ips_clk;

reg [31:0] ips_fnv;
reg [31:0] ips_cycle;

task ips_fnv_byte;
    input [7:0] b;
    begin
        ips_fnv = (ips_fnv ^ {24'd0, b}) * 32'h01000193;
    end
endtask

task ips_fnv_word;
    input [31:0] w;
    begin
        ips_fnv_byte(w[31:24]);
        ips_fnv_byte(w[23:16]);
        ips_fnv_byte(w[15:8]);
        ips_fnv_byte(w[7:0]);
    end
endtask

task ips_fnv_reset;
    begin
        ips_fnv = 32'h811c9dc5;
        ips_cycle = 32'd0;
    end
endtask

task ips_verdict;
    input ok;
    input [8*40-1:0] core;
    begin
        if (ok === 1'b1) begin
            $display("VERDICT %0s PASS D=%08h C=%0d", core, ips_fnv, ips_cycle);
            $finish;
        end else begin
            $display("VERDICT %0s FAIL D=%08h C=%0d", core, ips_fnv, ips_cycle);
            $fatal(1, "ip_series testbench verdict FAIL");
        end
    end
endtask
