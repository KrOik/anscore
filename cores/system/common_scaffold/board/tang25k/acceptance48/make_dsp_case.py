"""Freeze and simulate six public DSP board cases; never accesses JTAG.
python make_dsp_case.py --case fir --output <new-directory> --verify
"""
from pathlib import Path
import argparse, hashlib, json, math, random, shutil, sys, tempfile
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2];SV=COMMON/'signal_video';DSP=COMMON/'dsp'
sys.path.insert(0,str(COMMON/'integration'));sys.path.insert(0,str(DSP));sys.path.insert(0,str(HERE))
from tooling import execute
from make_case import rom, expected_line, bench
from cordic_reference import calculate
from fft_reference import transform

SPECS={
 'fir':('cip_fir_stream',8,'.DATA_W(8),.TAG_W(8),.COEFF_W(8),.TAPS(3),.SHIFT(1)','cip_dsp_fir'),
 'iir':('cip_iir_biquad_stream',8,'.DATA_W(8),.TAG_W(8),.COEFF_W(8),.SHIFT(6)','cip_dsp_iir_biquad'),
 'cic':('cip_cic_decimator',8,'.DATA_W(8),.TAG_W(8),.RATE(3),.STAGES(3),.SHIFT(4)','cip_dsp_cic_decimator'),
 'fft':('cip_fft_stream',16,'.DATA_W(16),.TAG_W(8),.LOG_N(3)','cip_dsp_fft'),
 'cordic':('cip_cordic_stream',16,'.DATA_W(16),.TAG_W(8)','cip_dsp_cordic'),
 'resampler':('cip_resampler_stream',8,'.DATA_W(8),.TAG_W(8),.COEFF_W(8),.TAPS(7),.SHIFT(6),.UP(3),.DOWN(2)','cip_dsp_resampler')}


def make_vectors(name):
 rng=random.Random(0xA48D);commands=[];inputs=[];outputs=[];width=SPECS[name][1];mask=(1<<width)-1
 def add(op,p0=0,p1=0,samples=None,result=None,error=0):
  si=samples or [];so=result or [];fields=[(op,0),((0x20+len(commands))&255,4),(p0&0xffffffff,76),(p1&0xffffffff,108),(len(si),236),(len(so),252),(error,300),(len(inputs),302),(len(outputs),318)]
  commands.append(sum(v<<shift for v,shift in fields));inputs.extend((v&mask)|(int(last)<<32) for v,last in si);outputs.extend((v&mask)|(int(last)<<32) for v,last in so)
 def packet(v):return [(x,i==len(v)-1) for i,x in enumerate(v)]
 def serial(values):
  result=[]
  for i,v in enumerate(values):
   for j,x in enumerate(v):result.extend([(x&65535,False),((x>>16)&65535,i==len(values)-1 and j==len(v)-1)])
  return result
 add(15,error=1)
 if name=='cordic':add(0,0,1,error=2)
 else:add(0,1,0,error=2)
 if name in ('fir','iir','resampler'):
  coeff={'fir':[3,-2,1],'iir':[32,16,-8,-32,12],'resampler':[32,-17,63,1,-7,13,4]}[name]
  for i,v in enumerate(coeff):add(1,i,v)
  add(1,len(coeff),5,error=2);add(1,0,255,error=2)
  packets=[[127],[-128,127,0,1,-1],[((i*73)%256)-128 for i in range(17)]]
  for values in packets:
   if name=='fir':
    expected=[max(-128,min(127,sum(c*values[i-j] for j,c in enumerate(coeff) if i>=j)>>1)) for i in range(len(values))]
   elif name=='iir':
    x1=x2=y1=y2=0;expected=[]
    for x in values:
     y=max(-128,min(127,(coeff[0]*x+coeff[1]*x1+coeff[2]*x2-coeff[3]*y1-coeff[4]*y2)>>6));expected.append(y);x2,x1,y2,y1=x1,x,y1,y
   else:
    inserted=[0]*((len(values)-1)*3+1);inserted[::3]=values
    convolution=[0]*(len(inserted)+len(coeff)-1)
    for i,x in enumerate(inserted):
     for j,c in enumerate(coeff):convolution[i+j]+=x*c
    expected=[max(-128,min(127,v>>6)) for v in convolution[::2]]
   add(0,samples=packet(values),result=packet(expected))
  # Change coefficients between complete packets; verify the new bank is used.
  for i in range(len(coeff)):add(1,i,64 if i==0 else 0)
  values=[-128,0,127]
  expected=[max(-128,min(127,x*(32 if name=='fir' else 1))) for x in values]
  if name=='resampler':
   expected=[values[i//3] if i%3==0 and i//3<len(values) else 0 for i in range(0,(len(values)-1)*3+len(coeff),2)]
  add(0,samples=packet(values),result=packet(expected))
 elif name=='cic':
  from math import comb
  for values in [[127],[-128,127],[127]*3,[-128]*4,[rng.randrange(-128,128) for _ in range(17)]]:
   checkpoints=[];expected=[]
   for i,x in enumerate(values):
    if (i+1)%3 and i!=len(values)-1:continue
    checkpoints.append(sum(comb(i-j+2,2)*v for j,v in enumerate(values[:i+1])))
    v=sum((-1)**j*comb(3,j)*checkpoints[-1-j] for j in range(min(4,len(checkpoints))))
    v=((v+(1<<13))%(1<<14))-(1<<13)
    expected.append(max(-128,min(127,v>>4)))
   add(0,samples=packet(values),result=packet(expected))
 elif name=='cordic':
  for mode in (0,1):
   for angle,x,y in [(0,20000,0),(25736,137,-891),(-25736,-32768,32767),(131071,32767,32767),(-131072,0,-32768)]:
    add(mode,angle,samples=[(x,False),(y,True)],result=serial([calculate(x,y,angle,mode)]))
  add(0,131072,error=2);add(1,0,1,error=2)
 else:
  patterns=[[(32767,-32768)]+[(0,0)]*7,[(1000,1000)]*8,[(rng.randrange(-32768,32768),rng.randrange(-32768,32768)) for _ in range(8)]]
  for mode in (0,1):
   for values in patterns:
    si=[]
    for i,(re,im) in enumerate(values):si.extend([(re,False),(im,i==7)])
    add(mode,samples=si,result=serial(transform(values,mode)))
  add(0,samples=[(123,True)],error=2)
  values=[(1000,0)]*8;si=[]
  for i,(re,im) in enumerate(values):si.extend([(re,False),(im,i==7)])
  add(1,samples=si,result=serial(transform(values,1)))
 return commands,inputs,outputs,[],[]


def render(name,vectors,corrupt=False):
 commands,inputs,outputs,aux,coeff=vectors
 if corrupt:outputs=outputs.copy();outputs[0]^=1
 module,width,params,_=SPECS[name];case_id=int.from_bytes({'fir':b'FIR8','iir':b'IIR8','cic':b'CIC8','fft':b'FFT8','cordic':b'CORD','resampler':b'RS32'}[name],'big')
 text=f"""module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!rst_n)begin if(&por)rst_n<=1'b1;else por<=por+1'b1;end end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ml;
wire [7:0] tag,rt;wire [1:0] re;wire [{width-1}:0] md;wire [31:0] ddata={{{32-width}'d0,md}};
wire [31:0] errors,digest;wire timed_out,finished;
"""
 text+=rom('configuration',384,commands,'ci')+rom('input_word',34,inputs,'ii')+rom('expected_word',34,outputs,'ei')
 text+=f"""
acceptance48_driver #(.COMMANDS({len(commands)}),.CASE_ID(32'h{case_id:08x}),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(34'd0),.expected_word(expected_word),.coefficient_word(48'd0),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(1'b0),.coeff_valid(kv),.coeff_ready(1'b0),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(1'b0),.m_eol(ml),.unexpected_memory(1'b0),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
{module} #({params}) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_opcode({{4'd0,configuration[3:0]}}),.cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),
 .s_data(input_word[{width-1}:0]),.s_valid(sv),.s_last(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_last(ml),.m_ready(mr));
endmodule
"""
 return text,case_id


def dependencies(name):
 module,_,_,core=SPECS[name]
 return [SV/'rtl'/f'{module}.v',DSP/'rtl'/f'{core}.v']+([DSP/'rtl/cip_dsp_fft_twiddle.v'] if name=='fft' else [])


def main():
 ap=argparse.ArgumentParser();ap.add_argument('--case',choices=list(SPECS),required=True);ap.add_argument('--output',type=Path,required=True);ap.add_argument('--verify',action='store_true');a=ap.parse_args();out=a.output.resolve()
 if out.exists() and any(out.iterdir()):raise RuntimeError('output must be new or empty; preserving baseline artifacts')
 out.mkdir(parents=True,exist_ok=True);source=out/'source';source.mkdir();vectors=make_vectors(a.case);top,case_id=render(a.case,vectors)
 (source/'acceptance48_top.v').write_text(top);shutil.copy2(HERE/'rtl/acceptance48_driver.v',source/'acceptance48_driver.v');staged=[source/'acceptance48_top.v',source/'acceptance48_driver.v']
 for dep in dependencies(a.case):target=source/dep.name;shutil.copy2(dep,target);staged.append(target)
 shutil.copy2(HERE.parent/'tang25k.cst',out/'tang25k.cst');golden=expected_line(vectors,case_id);(out/'expected_uart.txt').write_bytes(golden.encode('ascii'))
 (out/'vectors.json').write_text(json.dumps(dict(zip(['configuration','inputs','outputs','aux','coeff'],vectors)),indent=2)+'\n')
 if a.verify:
  with tempfile.TemporaryDirectory(prefix='a48_dsp_verify_') as tmp:
   temporary=Path(tmp)
   for kind in ['normal','pixel_fault','timeout']:
    variant=temporary/(kind+'.v');variant.write_text(render(a.case,vectors,kind=='pixel_fault')[0]);tb=temporary/(kind+'_tb.v');tb.write_text(bench(kind=='timeout'))
    fixture=temporary/(kind+'.txt');fixture.write_bytes(expected_line(vectors,case_id,0 if kind=='normal' else 1,int(kind=='timeout')).encode('ascii'));binary=temporary/(kind+'.vvp')
    execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,variant,*staged[1:],tb],out,out/(kind+'_compile.log'))
    result=execute(['vvp',binary,'+golden='+str(fixture)],out,out/(kind+'_simulation.log'))
    if 'ACCEPTANCE48 UART GOLDEN PASS' not in result:raise RuntimeError('missing UART verification marker')
  simulation='PASS'
 else:simulation='NOT_RUN'
 hashes={str(p.relative_to(out)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*staged,out/'tang25k.cst',out/'vectors.json',out/'expected_uart.txt']}
 refs=[Path(__file__),HERE/'make_case.py',DSP/'cordic_reference.py',DSP/'fft_reference.py',DSP/'iir_reference.py',DSP/'resampler_reference.py',SV/'cic_adapter_reference.py',SV/'sim/tb_cip_fir_stream.v']
 provenance={str(p.relative_to(COMMON)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in refs}
 info={'case':a.case,'public_module':SPECS[a.case][0],'top':'acceptance48_top','sources':[str(p.relative_to(out)).replace('\\','/') for p in staged],'simulation':simulation,'source_sha256':hashes,'oracle_source_sha256':provenance,'clock_hz':50000000,'uart_baud_nominal':115200,'uart_divisor':434,'ce_div':4,'timeout_cycles':50000000,'commands':len(vectors[0]),'inputs':len(vectors[1]),'outputs':len(vectors[2]),'coefficients':0,'expected_uart':golden,'scope':'Bounded public DSP adapter acceptance; all output words, last bits, response tags/errors compared. Finite signed fixed-point vectors and configured small parameters only. No board pass until actual JTAG/UART validation.','dut_parameters':SPECS[a.case][2]}
 (out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=hashlib.sha256((out/'case.json').read_bytes()).hexdigest();(out/'build_status.json').write_text(json.dumps({'status':'SIMULATION_PASS' if a.verify else 'GENERATED','simulation':simulation,'source_sha256':hashes},indent=2)+'\n')
 print(json.dumps({'case':str(out),'simulation':simulation,'expected_uart':golden,'commands':len(vectors[0]),'inputs':len(vectors[1]),'outputs':len(vectors[2])}))
if __name__=='__main__':main()
