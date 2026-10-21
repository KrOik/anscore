"""Freeze self-contained public-IP board acceptance cases; never programs hardware.
python make_case.py --case brightness --output <new-directory> --verify
"""
from pathlib import Path
import argparse,hashlib,json,math,random,shutil,sys,tempfile
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2];SV=COMMON/'signal_video'
sys.path.insert(0,str(COMMON/'integration'))
from tooling import execute

import importlib
class ProviderRegistry:
 def __init__(self):
  self.modules=[]
  for name in ['image_case_providers','filter_case_providers','isp_case_providers','multiframe_case_providers','advanced_case_providers']:
   try:self.modules.append(importlib.import_module(name))
   except ModuleNotFoundError as e:
    if e.name!=name:raise
  self.CASE_NAMES=[case for module in self.modules for case in module.CASE_NAMES]
 def owner(self,name):return next(m for m in self.modules if name in m.CASE_NAMES)
 def describe(self,name):return self.owner(name).describe(name)
 def make_vectors(self,name):return self.owner(name).make_vectors(name)
providers=ProviderRegistry()
BUILTINS=['brightness','gamma','scaler','invert','color_convert','threshold']
def describe_case(name):
 if providers is not None and name in providers.CASE_NAMES:return providers.describe(name)
 module={'brightness':'brightness_contrast','gamma':'gamma','scaler':'scaler','invert':'invert','color_convert':'color_convert','threshold':'threshold'}[name]
 parameters={'MAX_WIDTH':8,'MAX_HEIGHT':6,'PIXEL_W':8} if name=='scaler' else {'OTSU_WIDTH':4,'OTSU_HEIGHT':3,'ADAPTIVE_MAX_WIDTH':8} if name=='threshold' else {}
 return {'module':'cip_image_'+module,'data_w':8 if name=='threshold' else 24,'parameters':parameters,
  'case_id':int.from_bytes({'brightness':b'BRIT','gamma':b'GAMA','scaler':b'SCAL','invert':b'INVT','color_convert':b'COLR','threshold':b'THRS'}[name],'big'),
  'simulation_timeout_cycles':2000000 if name=='threshold' else 200000}

def pack(v,w,h):return [x|(int(i==0)<<33)|(int(i%w==w-1)<<32) for i,x in enumerate(v)]
def make_vectors(name):
 if providers is not None and name in providers.CASE_NAMES:return providers.make_vectors(name)
 rng=random.Random(48621);commands=[];inputs=[];outputs=[];coeff=[];aux=[]
 def add(mode,w,h,dw,dh,p0,p1,image=None,result=None,error=0,words=None):
  tag=0xa0+len(commands);ni=len(image or []);no=len(result or []);nk=len(words or [])
  fields=[(mode,0),(tag,4),(w,12),(h,28),(dw,44),(dh,60),(p0&0xffffffff,76),(p1,108),
    (ni,236),(no,252),(0,268),(nk,284),(error,300),(len(inputs),302),(len(outputs),318),(len(aux),334),(len(coeff),350)]
  commands.append(sum(v<<shift for v,shift in fields));inputs.extend(pack(image or [],w,h) if image else []);outputs.extend(pack(result or [],dw,dh) if result else []);coeff.extend(words or [])
 if name=='brightness':
  for w,h,offset,gain,pivot in [(4,3,23,384,128),(1,1,-512,0,255),(3,2,511,65535,0),(5,2,-31,173,71)]:
   image=[rng.randrange(1<<24) for _ in range(w*h)];result=[]
   for pixel in image:
    value=0
    for shift in [0,8,16]:
     q=((((pixel>>shift)&255)-pivot)*gain+128)//256+pivot+offset
     value|=max(0,min(255,q))<<shift
    result.append(value)
   add(0,w,h,w,h,offset,(pivot<<16)|gain,image,result)
  add(3,2,2,2,2,0,256,error=1);add(0,0,2,0,2,0,256,error=2)
 elif name=='gamma':
  image=[rng.randrange(1<<24) for _ in range(12)];add(0,4,3,4,3,0,0,image,image)
  add(0,2,2,2,2,1,0,error=2)
  for curve in [0,1]:
   table=[int(255*(i/255)**g+0.5) for g in ([0.45,1,2.2] if curve==0 else [2,0.5,1.3]) for i in range(256)]
   add(1,0,0,0,0,0,0,words=[(a<<32)|v for a,v in enumerate(table)])
   image=[rng.randrange(1<<24) for _ in range(20)]
   result=[sum(table[lane*256+((v>>shift)&255)]<<shift for lane,shift in enumerate([16,8,0])) for v in image]
   add(0,5,4,5,4,1,0,image,result)
  add(4,1,1,1,1,0,0,error=1)
 elif name=='invert':
  for w,h,mask in [(4,3,0xffffff),(1,1,0),(3,2,0x55aa5a),(5,4,0x0080ff)]:
   image=[rng.randrange(1<<24) for _ in range(w*h)];add(0,w,h,w,h,mask,0,image,[v^mask for v in image])
  add(1,2,2,2,2,0,0,error=1);add(0,2,2,2,2,1<<24,0,error=2)
 elif name=='color_convert':
  def clip(v):return max(0,min(255,v))
  for mode in [0,1,0,1]:
   image=[0,0xffffff,0xff0000,0x00ff00,0x0000ff,0x808080]+[rng.randrange(1<<24) for _ in range(14)];out=[]
   for v in image:
    a,b,c=(v>>16)&255,(v>>8)&255,v&255
    if mode==0:q=[(77*a+150*b+29*c+128)//256,(-43*a-85*b+128*c+128)//256+128,(128*a-107*b-21*c+128)//256+128]
    else:q=[a+(359*(c-128)+128)//256,a+(-88*(b-128)-183*(c-128)+128)//256,a+(454*(b-128)+128)//256]
    out.append((clip(q[0])<<16)|(clip(q[1])<<8)|clip(q[2]))
   add(mode,5,4,5,4,0,0,image,out)
  add(2,1,1,1,1,0,0,error=1);add(0,2,2,2,2,1,0,error=2)
 elif name=='threshold':
  for threshold,invert in [(0,0),(128,0),(128,1),(255,0)]:
   image=[0,127,128,129,254,255]+[rng.randrange(256) for _ in range(6)]
   add(0,4,3,4,3,threshold,invert,image,[255 if (v>=threshold)^bool(invert) else 0 for v in image])
  # Exhaustive scalar Otsu score using rational cross-multiplication, first tie.
  image=[0,0,10,10,100,100,200,200,255,255,40,180];hist=[image.count(i) for i in range(256)]
  best=-1;best_den=1;level=0;left_n=left_sum=0;total=sum(image)
  for t in range(256):
   left_n+=hist[t];left_sum+=hist[t]*t;right_n=12-left_n
   if left_n and right_n:
    numerator=(total*left_n-left_sum*12)**2;den=left_n*right_n
    if numerator*best_den>best*den:best=numerator;best_den=den;level=t
  for invert in [0,1]:add(1,4,3,4,3,0,invert,image,[255 if (v>level)^bool(invert) else 0 for v in image])
  for mode in [2,3]:
   for offset,invert in [(7,0),(-13,1)]:
    image=[rng.randrange(256) for _ in range(30)];out=[]
    for y in range(1,4):
     for x in range(1,5):
      coeff=[1]*9 if mode==2 else [1,2,1,2,4,2,1,2,1];den=sum(coeff)
      total=sum(image[(y+k//3-1)*6+x+k%3-1]*coeff[k] for k in range(9))
      out.append(255 if (image[y*6+x]*den>total-offset*den)^bool(invert) else 0)
    add(mode,6,5,4,3,offset,invert,image,out)
  add(4,2,2,2,2,0,0,error=1);add(0,2,2,2,2,256,0,error=2)
 else:
  sys.path.insert(0,str(SV));from run_scaler_tests import reference
  for w,h,dw,dh in [(3,2,5,4),(5,4,2,3),(1,4,3,2)]:
   image=[rng.randrange(1<<24) for _ in range(w*h)]
   for mode in [0,1]:
    out=[v&0xffffffff for v in reference(image,w,h,dw,dh,mode,8,3)]
    add(mode,w,h,dw,dh,0,0,image,out)
  add(3,2,2,2,2,0,0,error=1);add(0,9,2,2,2,0,0,error=2)
 return commands,inputs,outputs,aux,coeff

def rom(name,width,values,index):
 body=''.join(f"16'd{i}: {name}={width}'h{v:x};\n" for i,v in enumerate(values))
 return f"reg [{width-1}:0] {name};always @* begin {name}=0;case({index})\n{body}default:{name}=0;endcase end\n"

def render(name,vectors,corrupt=False):
 commands,inputs,outputs,aux,coeff=vectors
 if corrupt:outputs=outputs.copy();outputs[0]^=1
 meta=describe_case(name);module=meta['module'];dataw=meta['data_w']
 params=f'.DATA_W({dataw}),.TAG_W(8)'+''.join(f',.{k}({v})' for k,v in meta.get('parameters',{}).items())
 case_id=meta['case_id']
 text=f"""module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!(&por))por<=por+1'b1;rst_n<=&por;end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ms,me;
wire [7:0] tag,rt;wire [1:0] re;wire [{dataw-1}:0] md;wire [31:0] ddata=md;
wire mem_valid,mem_write,mem_response_ready;wire [31:0] errors,digest;wire timed_out,finished;
"""
 text+=rom('configuration',384,commands,'ci')+rom('input_word',34,inputs,'ii')+rom('expected_word',34,outputs,'ei')+rom('aux_word',34,aux,'ai')+rom('coefficient_word',48,coeff,'ki')
 text+=f"""
acceptance48_driver #(.COMMANDS({len(commands)}),.CASE_ID(32'h{case_id:08x}),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(aux_word),.expected_word(expected_word),.coefficient_word(coefficient_word),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(ar),.coeff_valid(kv),.coeff_ready(kr),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(ms),.m_eol(me),.unexpected_memory(mem_valid || mem_write || mem_response_ready),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
{module} #({params}) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_mode(configuration[3:0]),.cfg_src_width(configuration[27:12]),.cfg_src_height(configuration[43:28]),.cfg_dst_width(configuration[59:44]),.cfg_dst_height(configuration[75:60]),
 .cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),.cfg_frame_base(configuration[171:140]),.cfg_frame_stride(configuration[203:172]),.cfg_aux_base(configuration[235:204]),
 .coeff_valid(kv),.coeff_ready(kr),.coeff_addr(coefficient_word[47:32]),.coeff_data(coefficient_word[31:0]),
 .aux_data(aux_word[{dataw-1}:0]),.aux_valid(av),.aux_sof(aux_word[33]),.aux_eol(aux_word[32]),.aux_ready(ar),
 .mem_req_valid(mem_valid),.mem_req_write(mem_write),.mem_rsp_ready(mem_response_ready),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(input_word[{dataw-1}:0]),.s_valid(sv),.s_sof(input_word[33]),.s_eol(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
endmodule
"""
 return text,case_id

def dependencies(name):
 if providers is not None and name in providers.CASE_NAMES:return [Path(p) for p in providers.describe(name)['sources']]
 base=[SV/'rtl'/('cip_image_'+{'brightness':'brightness_contrast','gamma':'gamma','scaler':'scaler','invert':'invert','color_convert':'color_convert','threshold':'threshold'}[name]+'.v')]
 if name=='brightness':base += [SV/'rtl/cip_image_pointwise_frame_ctrl.v',SV/'rtl/cip_rgb_brightness_contrast.v']
 elif name=='invert':base += [SV/'rtl/cip_image_pointwise_frame_ctrl.v',COMMON/'image/geometry/rtl/img_geo_pixel_invert.v']
 elif name=='color_convert':base += [SV/'rtl/cip_image_pointwise_frame_ctrl.v',COMMON/'image/isp/img_isp_colorspace.v']
 elif name=='threshold':base += [SV/'rtl/cip_image_threshold_fixed.v',*[COMMON/'image/histogram/rtl'/n for n in ['img_hist_otsu_frame.v','img_hist_accumulator.v','img_hist_otsu_threshold.v','img_hist_serial_multiply.v']],COMMON/'image/pipelines/img_adaptive_threshold_frame.v',COMMON/'image/window/img_window3x3_valid_draft.v',*[COMMON/'image/filters/rtl'/n for n in ['img_filter_adaptive_mean3x3.v','img_filter_adaptive_gaussian3x3.v','img_filter_stream_register.v']]]
 elif name=='gamma':base += [SV/'rtl/cip_image_pointwise_frame_ctrl.v',COMMON/'image/isp/img_isp_gamma_lut.v']
 else:base += [SV/'rtl/cip_image_bicubic_frame.v',*sorted((COMMON/'image/geometry/rtl').glob('*.v'))]
 return base

def expected_line(vectors,case_id,errors=0,timeout=0):
 digest=0x811c9dc5
 if not timeout:
  for word in vectors[2]:digest=(((digest<<5)|(digest>>27))&0xffffffff) ^ (word&0xffffffff) ^ (((word>>33)&1)<<1) ^ ((word>>32)&1)
 return f'A48 {case_id:08X} {"FAIL" if errors else "PASS"} E={errors:08X} D={digest:08X} T={timeout}\r\n'

def bench(timeout=False,long=False):
 return """`timescale 1ns/1ps
module acceptance48_tb;
reg clk=0;always #10 clk=~clk;wire tx,dbg;
acceptance48_top #(.UART_DIV(8),.TIMEOUT_CYCLES(200000)) uut(.clk(clk),.uart_rx_pin(1'b1),.uart_tx(tx),.dbg_uart(dbg));
reg [7:0] value;integer i,j;reg [4095:0] golden;integer fd;reg [7:0] expected[0:44];
initial begin
 if(!$value$plusargs("golden=%s",golden))$fatal(1,"golden required");fd=$fopen(golden,"rb");for(j=0;j<45;j=j+1)expected[j]=$fgetc(fd);$fclose(fd);
"""+(" force uut.cr=0;\n" if timeout else '')+"""
 for(j=0;j<45;j=j+1)begin
  @(negedge tx);repeat(12)@(posedge clk);
  for(i=0;i<8;i=i+1)begin value[i]=tx;repeat(8)@(posedge clk);end
  if(tx!==1)$fatal(1,"UART stop bit");
  if(value!==expected[j])$fatal(1,"UART byte %0d actual=%h expected=%h",j,value,expected[j]);
 end
 repeat(100)@(posedge clk);if(!uut.finished)$fatal(1,"completion");
 $display("ACCEPTANCE48 UART GOLDEN PASS");$finish;
end
initial begin #300000000;$fatal(1,"simulation watchdog");end
endmodule
"""

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--case',choices=BUILTINS+(list(providers.CASE_NAMES) if providers is not None else []),required=True);ap.add_argument('--output',type=Path,required=True);ap.add_argument('--verify',action='store_true');a=ap.parse_args()
 out=a.output.resolve()
 if out.exists() and any(out.iterdir()):raise RuntimeError('output must be new or empty; baseline artifacts are preserved')
 out.mkdir(parents=True,exist_ok=True);source=out/'source';source.mkdir();vectors=make_vectors(a.case);top,case_id=render(a.case,vectors)
 (source/'acceptance48_top.v').write_text(top);shutil.copy2(HERE/'rtl/acceptance48_driver.v',source/'acceptance48_driver.v')
 staged=[source/'acceptance48_top.v',source/'acceptance48_driver.v']
 for dep in dependencies(a.case):
  if dep.name.startswith("tb_"):continue
  target=source/dep.name
  if target.exists():raise RuntimeError('duplicate source basename')
  shutil.copy2(dep,target);staged.append(target)
 shutil.copy2(HERE.parent/'tang25k.cst',out/'tang25k.cst');golden=expected_line(vectors,case_id);(out/'expected_uart.txt').write_bytes(golden.encode('ascii'))
 (out/'vectors.json').write_text(json.dumps({'configuration':vectors[0],'inputs':vectors[1],'outputs':vectors[2],'aux':vectors[3],'coeff':vectors[4]},indent=2)+'\n')
 verification=out/'verification';verification.mkdir();shutil.copy2(Path(__file__),verification/'reference_make_case.py')
 if providers is not None and a.case in providers.CASE_NAMES:shutil.copy2(Path(providers.owner(a.case).__file__),verification/('reference_'+Path(providers.owner(a.case).__file__).name))
 if (HERE/'case_provider_common.py').exists():shutil.copy2(HERE/'case_provider_common.py',verification/'reference_case_provider_common.py')
 verification_cases={}
 if a.verify:
  with tempfile.TemporaryDirectory(prefix='a48_verify_') as tmp:
   temporary=Path(tmp)
   for kind in ['normal','pixel_fault','timeout','response_fault','issue_output_fault','issue_response_fault','next_response_fault']:
    variant=temporary/(kind+'.v');variant.write_text(render(a.case,vectors,kind=='pixel_fault')[0]);tb=temporary/(kind+'_tb.v');bench_text=bench(kind=='timeout')
    if kind!="timeout":bench_text=bench_text.replace("TIMEOUT_CYCLES(200000)",f"TIMEOUT_CYCLES({describe_case(a.case).get('simulation_timeout_cycles',200000)})")
    inject=''
    if kind=='response_fault':inject=f"initial begin wait(uut.rst_n);wait(uut.ci==16'd{len(vectors[0])-1});force uut.re=2'd3;end\n"
    if kind in ['issue_output_fault','issue_response_fault']:
     signal='mv' if kind=='issue_output_fault' else 'rv'
     inject=f"initial begin wait(uut.rst_n);@(negedge clk);force uut.{signal}=1'b1;wait(uut.ce);@(posedge clk);@(negedge clk);release uut.{signal};end\n"
    if kind=='next_response_fault':inject="initial begin wait(uut.driver.state==2);@(negedge clk);force uut.rv=1'b1;wait(uut.ce);@(posedge clk);@(negedge clk);release uut.rv;end\n"
    tb.write_text(bench_text.replace('endmodule\n',inject+'endmodule\n'))
    fixture=temporary/(kind+'.txt');fixture.write_bytes(expected_line(vectors,case_id,0 if kind=='normal' else 1,int(kind=='timeout')).encode('ascii'));binary=temporary/(kind+'.vvp')
    shutil.copy2(tb,verification/tb.name);shutil.copy2(fixture,verification/(kind+'_expected_uart.txt'))
    top_variant='source/acceptance48_top.v'
    if kind=='pixel_fault':shutil.copy2(variant,verification/'pixel_fault_top.v');top_variant='verification/pixel_fault_top.v'
    verification_cases[kind]={'testbench':'verification/'+tb.name,'top_source':top_variant,'expected_uart':'verification/'+kind+'_expected_uart.txt','uart_divisor':8}
    execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,variant,*staged[1:],tb],out,out/(kind+'_compile.log'))
    text=execute(['vvp',binary,'+golden='+str(fixture)],out,out/(kind+'_simulation.log'))
    if 'ACCEPTANCE48 UART GOLDEN PASS' not in text:raise RuntimeError('missing UART verification')
  simulation='PASS'
 else:simulation='NOT_RUN'
 hashes={str(p.relative_to(out)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*staged,out/'tang25k.cst',out/'vectors.json',out/'expected_uart.txt',*verification.iterdir()]}
 info={'case':a.case,'public_module':describe_case(a.case)['module'],'dut_parameters':describe_case(a.case).get('parameters',{}),'data_w':describe_case(a.case)['data_w'],'top':'acceptance48_top','sources':[str(p.relative_to(out)).replace('\\','/') for p in staged],'simulation':simulation,'verification_cases':verification_cases,'source_sha256':hashes,'clock_hz':50000000,'uart_baud_nominal':115200,'uart_divisor':434,'ce_div':4,'timeout_cycles':50000000,'commands':len(vectors[0]),'inputs':len(vectors[1]),'outputs':len(vectors[2]),'coefficients':len(vectors[4]),'expected_uart':golden,'scope':'bounded public-wrapper full-output acceptance; external memory unsupported and requests fail'}
 (out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=hashlib.sha256((out/'case.json').read_bytes()).hexdigest()
 (out/'build_status.json').write_text(json.dumps({'status':'SIMULATION_PASS' if a.verify else 'GENERATED','simulation':simulation,'source_sha256':hashes},indent=2)+'\n')
 print(json.dumps({'case':str(out),'simulation':simulation,'expected_uart':golden}))
if __name__=='__main__':main()
