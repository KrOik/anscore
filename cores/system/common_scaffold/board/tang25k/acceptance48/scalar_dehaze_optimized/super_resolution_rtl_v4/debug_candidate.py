from pathlib import Path
import sys,tempfile,importlib.util
C=Path(__file__).resolve().parent;SV=C.parents[4]/'signal_video'
sys.path.insert(0,str(SV.parent/'integration'));from tooling import execute
spec=importlib.util.spec_from_file_location('ref',SV/'run_super_resolution_tests.py');ref=importlib.util.module_from_spec(spec);spec.loader.exec_module(ref)
with tempfile.TemporaryDirectory(prefix='sr_debug_') as t:
 d=Path(t);counts=ref.fixtures(d,8,1)
 tb=(SV/'sim/tb_cip_image_super_resolution.v').read_text().replace('endmodule','''
always @(posedge clk)if(dut.state==6 && dut.clk_en && ((^dut.sample_q)===1'bx || (^dut.coefficient_q)===1'bx))begin
 $display("UNKNOWN layer=%d xy=%d,%d oc=%d ic=%d tap=%d tapxy=%d,%d srcxy=%d,%d srcidx=%d fidx=%d widx=%d sample=%h coeff=%h width=%d",dut.layer,dut.x,dut.y,dut.oc,dut.ic,dut.tap,dut.tap_x,dut.tap_y,dut.sx,dut.sy,dut.source_index,dut.feature_index,dut.weight_index,dut.sample_q,dut.coefficient_q,dut.width);
 $fatal(1,"first unknown arithmetic operand");end
endmodule''')
 (d/'tb.v').write_text(tb);binary=d/'test.vvp'
 execute(['iverilog','-g2012','-s','tb_cip_image_super_resolution','-Ptb_cip_image_super_resolution.DW=8','-Ptb_cip_image_super_resolution.F=1','-o',binary,C/'source/cip_image_super_resolution.v',d/'tb.v'],C,C/'debug_compile.log')
 print(execute(['vvp',binary,f'+folder={d}',*[f'+{k}={counts[k]}' for k in ['commands','inputs','outputs','weights']]],C,C/'debug_simulation.log'))
