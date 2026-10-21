"""Exercise every supported nonzero16-bit sigma in the real production RTL."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[5]
RTL=ROOT/'cores/system/common_scaffold/image/filters/rtl'
sys.path.insert(0,str(ROOT/'cores/signal_processing/dsp_isp_library/board/tang25k'))
import device_flow

BENCH=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #10 clk=~clk;
reg rst_n=0;integer cycle=0;
always @(negedge clk)cycle=cycle+1;
wire ce=cycle%13!=2&&cycle%13!=7&&cycle%13!=11;
reg cv=0;reg [15:0] ss=0,sr=0;reg [7:0] tag=0;
wire cr,rv,ready;wire [7:0] rt,re;
img_filter_bilateral3x3 dut(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .cfg_sigma_spatial_q8(ss),.cfg_sigma_range_q8(sr),
 .rsp_valid(rv),.rsp_ready(1'b1),.rsp_tag(rt),.rsp_error(re),
 .s_taps(72'd0),.s_valid(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_ready(ready),
 .m_data(),.m_valid(),.m_sof(),.m_eol(),.m_ready(1'b1));
integer i,accepted=0,responses=0;
reg [63:0] expected_s,expected_r;
always @(posedge clk)if(rst_n&&ce)begin
 if(cv&&cr)accepted=accepted+1;
 if(rv)begin
  if(re!==0||rt!==tag)$fatal(1,"configuration response");
  responses=responses+1;
 end
end
initial begin
 repeat(3)@(negedge clk);rst_n=1;
 for(i=1;i<=65535;i=i+1)begin
  @(negedge clk);while(!cr)@(negedge clk);
  ss=i;sr=65536-i;tag=i;cv=1;
  expected_s={48'd0,ss}*{48'd0,ss};expected_r={48'd0,sr}*{48'd0,sr};
  @(posedge clk);while(!(ce&&cr))@(posedge clk);
  @(negedge clk);cv=0;
  while(!ready)@(negedge clk);
  if(dut.spatial_square!==expected_s[31:0]||dut.range_square!==expected_r[31:0])
    $fatal(1,"sigma%0d got%h/%h expected%h/%h",i,dut.spatial_square,dut.range_square,expected_s,expected_r);
 end
 repeat(4)@(negedge clk);
 if(accepted!=65535||responses!=65535)$fatal(1,"configuration counts");
 $display("BILATERAL ALL SIGMA SQUARES PASS configurations=%0d checked_sigma_fields=131070 CE pauses exact64-bit golden",accepted);$finish;
end
initial begin #20000000;$fatal(1,"sigma sweep watchdog");end
endmodule
'''


def main():
    stamp=datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    evidence=HERE/('sigma_sweep_'+stamp)
    evidence.mkdir()
    with tempfile.TemporaryDirectory(prefix='.sigma_sweep_',dir=HERE) as td:
        temporary=Path(td)
        bench=temporary/'tb.sv'
        bench.write_text(BENCH)
        image=temporary/'test.vvp'
        command=[device_flow.resolve('iverilog'),'-g2012','-Wall','-s','tb','-o',str(image),str(RTL/'img_filter_bilateral3x3.v'),str(RTL/'img_filter_exp_weight.v'),str(bench)]
        compiled=subprocess.run(command,env=device_flow.tool_env(),capture_output=True,text=True,timeout=45)
        (evidence/'compile.log').write_text(compiled.stdout+compiled.stderr)
        assert compiled.returncode==0,compiled.stdout+compiled.stderr
        run=subprocess.run([device_flow.resolve('vvp'),str(image)],env=device_flow.tool_env(),capture_output=True,text=True,timeout=90)
        output=run.stdout+run.stderr
        (evidence/'simulation.log').write_text(output)
        print(output,end='',flush=True)
        assert run.returncode==0 and 'BILATERAL ALL SIGMA SQUARES PASS' in output,output
    summary=dict(status='PASS',configurations=65535,checked_sigma_fields=131070,
                 coverage='Every supported nonzero16-bit spatial sigma and range sigma tested in real production configuration pipeline; independent64bit square oracle; CE pauses and exact response counts',
                 production_sha256=hashlib.sha256((RTL/'img_filter_bilateral3x3.v').read_bytes()).hexdigest(),
                 temporary_images_removed=True,board_scope_unchanged=True)
    (evidence/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('evidence='+str(evidence))


if __name__=='__main__':main()
