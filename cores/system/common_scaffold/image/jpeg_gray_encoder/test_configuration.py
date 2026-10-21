from test_frame import *

def main():
 results=[]
 for name,reject in [('atomic_valid_update',False),('atomic_rejected_zero',True)]:
  tb=TB.replace('WW','13').replace('HH','9').replace('RI','2')
  tb=tb.replace('reg rst=0,',"reg[7:0]qval=8;reg checking_bad=0;reg rst=0,").replace(".table_value(8'd8)",'.table_value(qval)')
  tb=tb.replace('if(err||cerr)$fatal(1,"error %h",err);','if(err||(cerr&&!checking_bad))$fatal(1,"error %h",err);')
  mark='for(integer k=0;k<2;k=k+1)begin'
  injection=f"""
checking_bad={int(reject)};
for(integer i=0;i<64;i=i+1)begin @(negedge clk);ti=i;qval={0 if reject else 12};tv=1;@(posedge clk);while(!tr)@(posedge clk);end
@(negedge clk);tv=0;cv=1;@(posedge clk);while(!cr)@(posedge clk);
@(negedge clk);cv=0;wait(cd);if(cerr!={int(reject)})$fatal(1,"atomic config status");repeat(2)@(negedge clk);checking_bad=0;
"""
  tb=tb.replace(mark,injection+mark)
  with tempfile.TemporaryDirectory(prefix='jpeg_cfg_') as tmp:
   p=Path(tmp);rng=random.Random(123);pixels=[rng.randrange(256) for _ in range(13*9*2)]
   (p/'pixels.hex').write_text(''.join(f'{x:02x}\n' for x in pixels));(p/'tb.sv').write_text(tb)
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,HERE/'jpeg_gray_encoder.sv',p/'tb.sv'],p,HERE/f'{name}_compile.log')
   out=execute(['vvp',p/'sim'],p,HERE/f'{name}_simulation.log');assert 'GRAY_FRAME PASS' in out
   for f in range(2):
    data=bytes(int(x,16) for x in (p/f'frame{f}.hex').read_text().split());image=Image.open(io.BytesIO(data));image.load()
    q=8 if reject else 12;assert image.quantization[0]==[q]*64
    block=pixels[f*117:(f+1)*117];error=max(abs(x-y) for x,y in zip(block,image.tobytes()));assert error<=22
    results.append(dict(profile=name,frame=f,qtable=q,max_error=error,status='PASS'))
 (HERE/'configuration_result.json').write_text(json.dumps(dict(status='PASS',profiles=results),indent=2));print('PASS',len(results),'atomic config frames')
if __name__=='__main__':main()

