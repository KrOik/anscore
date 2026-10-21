"""Direct RTL helper verification with independent abs/divmod nearest-even oracle."""
import os,sys,subprocess,json,hashlib
from pathlib import Path
from datetime import datetime
BASE=Path(__file__).resolve().parents[1];ROOT=BASE.parents[3]
sys.path.insert(0,str(BASE/'models'))
from dc_reference import rne
RTL=BASE/'candidates/fixed_width_round_v2/dc_stream.sv'
OUT=BASE/'evidence'/('rounding_v2_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));OUT.mkdir()
values=[q*65536+r for q in [-2,-1,0,1] for r in range(65536)]
values += [q*65536+r for q in [-98305,-98304,-65537,-65536,-32768,32767,65536,65537,98304] for r in [0,1,32767,32768,32769,65535]]
(OUT/'output.mem').write_text('\n'.join(f'{v&((1<<34)-1):09x} {rne(v,65536)&0xffffffff:08x}' for v in values)+'\n')
pv=[q*65536+r for q in [-(1<<32)-32768,-(1<<31),-2,-1,0,1,2,(1<<31)-65536,(1<<32)+32768] for r in [0,1,32767,32768,32769,65535]]
(OUT/'product.mem').write_text('\n'.join(f'{v&((1<<52)-1):013x} {rne(v,65536)&((1<<36)-1):09x}' for v in pv)+'\n')
tb='''module tb;
dc_stream dut();
integer f,n,count;reg signed[33:0] v;reg signed[17:0] got;reg signed[31:0] expect32;
reg signed[51:0] p;reg signed[35:0] expected36,got36;
initial begin
 count=0;f=$fopen("output.mem","r");
 while(!$feof(f))begin
  n=$fscanf(f,"%h %h\\n",v,expect32);if(n!=2)$fatal(1,"fixture");
  got=dut.output_round(v);
  if($signed(got)!==expect32)$fatal(1,"output rounding value=%d actual=%d expected=%d",v,got,expect32);
  count=count+1;
 end
 $fclose(f);f=$fopen("product.mem","r");
 while(!$feof(f))begin
  n=$fscanf(f,"%h %h\\n",p,expected36);if(n!=2)$fatal(1,"fixture");
  got36=dut.product_round(p);
  if(got36!==expected36)$fatal(1,"product rounding value=%d actual=%d expected=%d",p,got36,expected36);
  count=count+1;
 end
 $display("PASS rounding cases=%0d",count);$finish;
end
endmodule
'''
(OUT/'tb.sv').write_text(tb)
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
for cmd,name in [([str(tool/'bin/iverilog.exe'),'-g2012','-s','tb','-o','test.vvp',str(RTL),'tb.sv'],'compile.log'),([str(tool/'bin/vvp.exe'),'test.vvp'],'run.log')]:
 p=subprocess.run(cmd,cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(OUT/name).write_text(p.stdout)
 if p.returncode:raise RuntimeError(p.stdout)
summary={'status':'PASS','output_cases':len(values),'product_cases':len(pv),'source_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),
 'scope':'all 65536 fractional residues at signed quotient -2,-1,0,1 plus reachable range boundaries; source simulation only'}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2));print(OUT);print(json.dumps(summary,indent=2))
