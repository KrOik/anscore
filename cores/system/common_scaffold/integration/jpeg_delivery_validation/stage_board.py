"""Stage and route standard-API JPEG only after the complete delivery regression."""
import pathlib,json,hashlib,sys,tempfile,shutil
H=pathlib.Path(__file__).resolve().parent;P=H.parents[1];R=P.parents[1]
sys.path.insert(0,str(P/'integration'));from tooling import execute
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 regression=H/'registered_accumulator_full_20261020/results.json';assert json.loads(regression.read_text())['status']=='PASS'
 bundle=R/'delivery/jpeg_gray_encoder_v2';manifest=json.loads((bundle/'sources_map.json').read_text());original=P/'board/tang25k/extension_acceptance/jpeg';dest=original.parent/'jpeg_delivery_v2';dest.mkdir(exist_ok=False)
 files=[bundle/row['delivery'] for row in manifest['files']]
 for row,p in zip(manifest['files'],files):assert sha(p)==row['delivery_sha256']
 files += [R/'cores/crypto/hybrid_lattice_ntt/src/uart_tx.v',original/'jpeg_uart_25k.sv']
 inputs={str(p.resolve()):sha(p) for p in [*files,regression,bundle/'sources_map.json',original/'expected_uart.bin',original/'simulation_gate.json',original/'pixels.hex',pathlib.Path(__file__)]}
 for p in files:shutil.copy2(p,dest/p.name)
 for n in ['expected_uart.bin','pixels.hex']:shutil.copy2(original/n,dest/n)
 expected=(dest/'expected_uart.bin').read_bytes();assert len(expected)==999
 # Actual 50MHz clock, 115200 divider434, half-bit217; short reset-only boot.
 tb='''`timescale 1ns/1ps
module tb;
reg clk=0;always #10 clk=~clk;wire tx,done;
jpeg_uart_25k #(.CLK_HZ(50000000),.BAUD(115200),.BOOT_CYCLES(32))dut(.clk(clk),.uart_rx_pin(1'b1),.uart_tx(tx),.dbg_uart(done));
integer f,count=0;reg[7:0]b;
initial begin f=$fopen("uart.hex","w");forever begin
@(negedge tx);repeat(651)@(posedge clk);
for(integer i=0;i<8;i=i+1)begin b[i]=tx;repeat(434)@(posedge clk);end
if(tx!==1)$fatal(1,"bad UART stop");$fdisplay(f,"%02x",b);count=count+1;
end end
initial begin wait(done);repeat(1000)@(posedge clk);if(count!=999)$fatal(1,"count %d",count);$fclose(f);$display("ACTUAL50 JPEG UART PASS");$finish;end
initial begin #300000000;$fatal(1,"timeout");end
endmodule
'''
 (dest/'uart_tb.sv').write_text(tb,encoding='utf-8')
 with tempfile.TemporaryDirectory(prefix='jpeg_delivery_actual50_') as tmp:
  work=pathlib.Path(tmp);execute(['iverilog','-g2012','-s','tb','-o',work/'sim',*[dest/p.name for p in files],dest/'uart_tb.sv'],work,dest/'uart_compile.log');output=execute(['vvp',work/'sim'],work,dest/'uart_simulation.log',timeout=240)
  actual=bytes.fromhex((work/'uart.hex').read_text());assert actual==expected and 'ACTUAL50 JPEG UART PASS' in output
  (dest/'actual_uart.bin').write_bytes(actual)
 sys.path.insert(0,str(P/'board/tang25k/acceptance48'));import build_case
 build_case.route.device_flow.write_cst(dest)
 (dest/'expected_uart.txt').write_text(expected.hex()+'\n',encoding='utf-8')
 (dest/'case.json').write_text(json.dumps(dict(top='jpeg_uart_25k',sources=[p.name for p in files]),indent=2)+'\n',encoding='utf-8')
 frozen={p.name:sha(p) for p in dest.iterdir() if p.is_file()}
 (dest/'build_status.json').write_text(json.dumps(dict(simulation='PASS',source_sha256=frozen,scope='50MHz 115200 UART bit sampling, 999 original golden bytes; 32cycle simulation boot, production default50M boot'),indent=2)+'\n',encoding='utf-8')
 tracked={**inputs,**{str(p.resolve()):sha(p) for p in dest.iterdir() if p.is_file()}}
 (dest/'source_manifest.json').write_text(json.dumps(dict(status='PASS',files=tracked),indent=2)+'\n',encoding='utf-8')
 try:rc=build_case.build(dest,'jpeg_delivery_v2',R/'scratch/bram_timing_db_20261017/GW5A-25A_patched.bin',no_lutram=True)
 finally:
  stable=all(sha(pathlib.Path(n))==v for n,v in tracked.items());(dest/'build_input_sha256.json').write_text(json.dumps(dict(status='PASS_BUILD_INPUT_STABLE' if stable else 'FAIL_INPUT_CHANGED',files=tracked,full_netlists_retained=True),indent=2)+'\n',encoding='utf-8')
 print('route return',rc,'source stable',stable)
 if rc:raise SystemExit(rc)
if __name__=='__main__':main()
