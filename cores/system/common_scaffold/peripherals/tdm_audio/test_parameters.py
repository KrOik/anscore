from run_tests import *
def main():
 rows=[]
 for rtl in SOURCES:
  for k,v in [('SLOTS',1),('SLOTS',17),('SLOT_BITS',8),('SLOT_BITS',48),('SAMPLE_BITS',0),('SAMPLE_BITS',33),('FS_POLARITY',2),('FS_PULSE_BITS',0),('FS_PULSE_BITS',256),('DELAY_BITS',2),('FIFO_FRAMES',1),('FIFO_FRAMES',9)]:
   with tempfile.TemporaryDirectory(prefix='tdm_param_') as td:
    d=Path(td);(d/'tb.sv').write_text(f'module tb;{rtl.stem} #(.{k}({v})) dut();initial begin #2;$finish;end endmodule');label=f'invalid_{rtl.stem}_{k}_{v}'
    try:
     execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',rtl,d/'tb.sv'],H,H/(label+'_compile.log'))
     execute(['vvp',d/'a.vvp'],H,H/(label+'_simulation.log'))
    except RuntimeError as e:
     assert 'invalid TDM' in str(e) or (k=='SAMPLE_BITS' and v==0 and ('part select width' in str(e) or 'Concatenation repeat' in str(e))),str(e)
    else:raise AssertionError('invalid parameters accepted')
   rows.append(dict(module=rtl.stem,parameter=k,value=v,status='REJECTED'))
 (H/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),profiles=rows),indent=2)+'\n');print('PASS24 invalid TDM configurations explicitly rejected')
if __name__=='__main__':main()
