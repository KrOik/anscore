from test_frame import *

def main():
 results=[]
 for name,target,bad in [('abort_header',3,0),('abort_app0',4,0),('abort_scan',6,0),('abort_eoi',8,0),('missing_sof',6,1),('early_eol',6,2)]:
  tb=TB.replace('WW','8').replace('HH','8').replace('RI','0')
  tb=tb.replace('reg rst=0,','reg abort=0;reg rst=0,').replace('.abort(1\'b0)','.abort(abort)')
  tb=tb.replace('if(err||cerr)$fatal(1,"error %h",err);','if(cerr)$fatal(1,"config error");')
  if bad==1:tb=tb.replace('.s_sof(sent==0)','.s_sof(1\'b0)')
  if bad==2:tb=tb.replace('.s_eol(sent%W==W-1)','.s_eol(1\'b1)')
  begin=tb.index('for(integer k=0;k<2;k=k+1)begin')
  tb=tb[:begin]+f"""
frame=0;sent=0;f=$fopen("unused.hex","w");start=1;
@(posedge clk);while(!sr)@(posedge clk);@(negedge clk);start=0;run=1;
wait(dut.state=={target});
"""+("@(negedge clk);run=0;ce=1;abort=1;" if not bad else '')+f"""
wait(dv);@(negedge clk);run=0;ce=0;
if(err!=8'h{('92' if bad else '93')})$fatal(1,"wrong terminal error %h",err);
repeat(4)begin @(posedge clk);if(!dv||pr||sr)$fatal(1,"error boundary");end
@(negedge clk);ce=1;dr=1;@(posedge clk);@(negedge clk);dr=0;abort=0;
repeat(4)begin @(posedge clk);if(dv||pr||sr||!busy)$fatal(1,"failure must lock");end
@(negedge clk);rst=0;@(posedge clk);@(negedge clk);rst=1;
@(posedge clk);@(negedge clk);if(err||busy||dv||sr)$fatal(1,"reset must invalidate config");
$fclose(f);$display("ERROR_CASE PASS");$finish;end
endmodule
"""
  with tempfile.TemporaryDirectory(prefix='jpeg_error_') as tmp:
   p=Path(tmp);(p/'tb.sv').write_text(tb);(p/'pixels.hex').write_text('80\n'*128)
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,HERE/'jpeg_gray_encoder.sv',p/'tb.sv'],p,HERE/f'{name}_compile.log')
   out=execute(['vvp',p/'sim'],p,HERE/f'{name}_simulation.log');assert 'ERROR_CASE PASS' in out
  results.append(dict(profile=name,status='PASS'))
 (HERE/'error_result.json').write_text(json.dumps(dict(status='PASS',profiles=results),indent=2));print('PASS',len(results),'error cases')
if __name__=='__main__':main()
