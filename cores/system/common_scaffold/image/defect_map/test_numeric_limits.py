"""Exact tie rounding, accumulator extremes, longest-axis geometry and rejected parameters."""
from run_tests import H,ROOT,RTL,execute,run_case,oracle
import numpy as np,tempfile,json,hashlib
from pathlib import Path

def main():
 rows=[]
 for bits in (8,10,12):
  peak=(1<<bits)-1;cases=[]
  for donor_values in ([0,0,1,1],[0,0,0,1],[peak]*4,[peak,peak,peak-1,peak-1]):
   a=np.full((5,5),peak,dtype=np.int64);mask=np.ones((5,5),dtype=np.uint8)
   for (y,x),value in zip([(0,2),(2,0),(2,4),(4,2)],donor_values):a[y,x]=value;mask[y,x]=0
   out,status=oracle(a,mask,17);assert out[2,2]==(sum(donor_values)+2)//4 and status[2,2]==1
   cases.append((a,mask,17))
  rows.append(run_case(f'numeric_ties_b{bits}',bits,(5,5),cases))
 for shape in ((1,256),(256,1)):
  a=np.full(shape,4095,dtype=np.int64);mask=np.zeros(shape,dtype=np.uint8);mask.flat[0]=1
  rows.append(run_case(f'max_axis_{shape[0]}x{shape[1]}',12,shape,[(a,mask,7),(a,1-mask,7)]))
 rejects=[]
 for i,params in enumerate([{'BITS':9},{'WIDTH':0},{'HEIGHT':0},{'WIDTH':257},{'HEIGHT':257},{'N':193},{'AW':1}]):
  with tempfile.TemporaryDirectory(prefix='defect_parameter_') as td:
   d=Path(td);(d/'tb.sv').write_text('module tb; defect_map #('+','.join('.%s(%d)'%(k,v) for k,v in params.items())+')dut();initial #2 $finish;endmodule')
   execute(['iverilog','-g2012','-s','tb','-o',str(d/'a.vvp'),str(RTL),str(d/'tb.sv')],ROOT,H/'parameter_compile.log')
   try:execute(['vvp',str(d/'a.vvp')],ROOT,H/'parameter_last_rejection.log');raise AssertionError('illegal parameters accepted')
   except RuntimeError:rejects.append(params)
 (H/'numeric_evidence.json').write_text(json.dumps({'result':'PASS','rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),'cases':rows,'rejected_parameters':rejects,'rounding':'all nearest ties mean half-up, including exact .5 and unsigned maxima'},indent=2)+'\n');print('PASS defect_map numeric limits')
if __name__=='__main__':main()
