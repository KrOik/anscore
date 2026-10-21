from pathlib import Path
import sys,tempfile,json,hashlib,random
H=Path(__file__).resolve().parent;sys.path.insert(0,str(H.parents[1]));from integration.tooling import execute
SOURCES={n:hashlib.sha256((H/n).read_bytes()).hexdigest() for n in ('raw16_pack.sv','raw16_unpack.sv')}
def model(kind,tokens,endian):
 output=[];errors=[];locked=False;first=None;gs=0;order='big' if endian else 'little'
 for data,sof,eol in tokens:
  if kind=='pack':
   if not locked and not sof:errors.append(4);continue
   locked=True;b=data.to_bytes(2,order);output.extend([(b[0],sof,0),(b[1],0,eol)]);continue
  if eol and (first is None or sof):first=None;locked=False;errors.append(2)
  elif sof and first is not None:first=data;gs=1;locked=True;errors.append(3)
  elif not locked and not sof:first=None;errors.append(4)
  elif first is None:first=data;gs=sof;locked=True
  else:output.append((int.from_bytes(bytes([first,data]),order),gs,eol));first=None
 return output,errors
TB=r'''module tb;
localparam IW=@IW@,OW=@OW@;reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1;reg[IW-1:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0;wire s_ready;wire[OW-1:0]m_data;wire m_valid,m_sof,m_eol;reg m_ready=0,error_ready=0;wire protocol_error,error_valid;wire[7:0]error_code;wire[31:0]error_count;
@INSTANCE@
reg[17:0]stim[0:@NI@-1],expectation[0:@NE@-1];integer sent=0,got=0,cycles=0;reg[31:0]rng=32'h1234abcd;reg drive=1,held=0;reg[OW+1:0]heldword;
always @(negedge clk)if(rst_n&&drive)begin
 ce=rng[0]||rng[5];m_ready=rng[2]||rng[7];
 s_valid=sent<@NI@;if(sent<@NI@)begin s_data=stim[sent][IW-1:0];s_sof=stim[sent][16];s_eol=stim[sent][17];end
end
always @(posedge clk)if(rst_n)begin
 cycles=cycles+1;if(cycles>3000000)$fatal(1,"watchdog sent%0d got%0d",sent,got);
 rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
 if(held&&(!m_valid||{m_sof,m_eol,m_data}!==heldword))$fatal(1,"held output changed");
 held=m_valid&&!(ce&&m_ready);heldword={m_sof,m_eol,m_data};
 if(s_valid&&s_ready)sent=sent+1;
 if(m_valid)begin
 if(got>=@NO@||m_data!==expectation[got][OW-1:0]||m_sof!==expectation[got][16]||m_eol!==expectation[got][17])$fatal(1,"output mismatch got%0d data%h want%h",got,m_data,expectation[got]);
 if(ce&&m_ready)got=got+1;
 end
end
initial begin $readmemh("@STIM@",stim);$readmemh("@EXPECT@",expectation);repeat(3)@(negedge clk);#1;rst_n=1;
while(sent<@NI@||got<@NO@)@(negedge clk);repeat(12)@(negedge clk);#1;drive=0;ce=0;s_valid=0;error_ready=1;
if(error_count!=@ERRORS@||protocol_error!==(@ERRORS@!=0)||error_valid!==(@ERRORS@!=0))$fatal(1,"erroraccount count%0d code%0d",error_count,error_code);
if(@ERRORS@!=0&&error_code!=@FIRST@)$fatal(1,"firsterror held");
repeat(5)@(negedge clk);#1;if(error_valid!==(@ERRORS@!=0))$fatal(1,"CEoff errorack");ce=1;@(negedge clk);#1;if(error_valid)$fatal(1,"errorack");
$display("PASS RAW16 @KIND@ input=%0d output=%0d errors=%0d cycles=%0d",sent,got,error_count,cycles);$finish;end endmodule'''
def run(kind,label,tokens,endian=0):
 expected,errors=(list(tokens),[]) if kind=='chain' else model(kind,tokens,endian);iw,ow=(16,16) if kind=='chain' else (16,8) if kind=='pack' else (8,16)
 instance=f'raw16_{kind} #(.BIG_ENDIAN({endian})) dut(.*);'
 if kind=='chain':instance=r'''wire[7:0]ld;wire lv,lr,ls,le,pe0,pe1,ev0,ev1;wire[7:0]ec0,ec1;wire[31:0]en0,en1;
 assign protocol_error=pe0||pe1;assign error_valid=ev0||ev1;assign error_code=ev0?ec0:ec1;assign error_count=en0+en1;
 raw16_pack #(.BIG_ENDIAN(@ENDIAN@)) a(.clk(clk),.rst_n(rst_n),.ce(ce),.s_data(s_data),.s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_ready(s_ready),.m_data(ld),.m_valid(lv),.m_sof(ls),.m_eol(le),.m_ready(lr),.protocol_error(pe0),.error_valid(ev0),.error_ready(error_ready),.error_code(ec0),.error_count(en0));
 raw16_unpack #(.BIG_ENDIAN(@ENDIAN@)) b(.clk(clk),.rst_n(rst_n),.ce(ce),.s_data(ld),.s_valid(lv),.s_sof(ls),.s_eol(le),.s_ready(lr),.m_data(m_data),.m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),.m_ready(m_ready),.protocol_error(pe1),.error_valid(ev1),.error_ready(error_ready),.error_code(ec1),.error_count(en1));'''

 with tempfile.TemporaryDirectory(prefix='raw16_codec_') as td:
  p=Path(td)
  for name,values in [('stim.hex',tokens),('expect.hex',expected or [(0,0,0)])]:(p/name).write_text('\n'.join(f'{d|(sof<<16)|(eol<<17):05x}' for d,sof,eol in values)+'\n')
  tb=TB
  for k,v in dict(IW=iw,OW=ow,NI=len(tokens),NO=len(expected),NE=max(1,len(expected)),INSTANCE=instance,STIM=(p/'stim.hex').as_posix(),EXPECT=(p/'expect.hex').as_posix(),ERRORS=len(errors),FIRST=errors[0] if errors else 0,KIND=kind,ENDIAN=endian).items():tb=tb.replace('@'+k+'@',str(v))
  (p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*(list(H.glob('raw16_*.sv')) if kind=='chain' else [H/f'raw16_{kind}.sv']),p/'tb.sv'],H,H/f'{label}_{kind}_e{endian}_compile.log');out=execute(['vvp',p/'sim'],H,H/f'{label}_{kind}_e{endian}_simulation.log');assert 'PASS RAW16' in out
 print(out.splitlines()[0]);return dict(name=label,big_endian=endian,module='raw16_'+kind,status='PASS',input_tokens=len(tokens),output_tokens=len(expected),errors=errors,output=out)
def frame(pixels,width):return [(v,int(i==0),int(i%width==width-1)) for i,v in enumerate(pixels)]
def byte_frame(pixels,width,endian):return model('pack',frame(pixels,width),endian)[0]
def main():
 rows=[]
 for endian in (0,1):
  assert model('pack',[(0x1234,1,1)],endian)[0]==([(0x12,1,0),(0x34,0,1)] if endian else [(0x34,1,0),(0x12,0,1)])
  pixels=list(range(65536));rows.extend([run('pack','all_values',frame(pixels,256),endian),run('unpack','all_values',byte_frame(pixels,256,endian),endian)])
  rng=random.Random(73)
  for width,height in [(1,4),(3,23),(17,19),(255,31)]:
   pixels=[rng.randrange(65536) for _ in range(width*height)];rows.extend([run('pack',f'random_{width}_{height}',frame(pixels,width),endian),run('unpack',f'random_{width}_{height}',byte_frame(pixels,width,endian),endian)])
 (H/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,scope='Every 16-bit value; independent Python int.to_bytes/from_bytes oracle; both byte orders; SOF/EOL CE/backpressure stability',profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
