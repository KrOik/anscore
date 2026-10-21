from pathlib import Path
import sys,tempfile,json,hashlib,random
H=Path(__file__).resolve().parent;sys.path.insert(0,str(H.parents[1]));from integration.tooling import execute
RTL=H/'video_frame_rate_converter.sv'
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,cadence_tick=0;
reg[15:0]cfg_width=@W@,cfg_height=@H@,cfg_rate_num=@NUM@,cfg_rate_den=@DEN@;
localparam PW=@PW@;reg[7:0]raw_pixel=0;wire[PW-1:0]s_pixel=raw_pixel*32'h01010101;reg s_valid=0,s_sof=0,s_eol=0,s_last=0;wire s_ready;wire[PW-1:0]m_pixel;wire m_valid,m_sof,m_eol,m_last;reg m_ready=0;wire[31:0]m_frame_id;wire start_ready,running,done_valid;reg done_ready=0;wire[7:0]error_code;wire[31:0]published_count,output_count,dropped_count,repeated_count,underrun_count,tick_overrun_count;
video_frame_rate_converter #(.PIXEL_W(PW),.MAX_WIDTH(@MW@),.MAX_HEIGHT(@MH@))dut(.*);
reg[31:0]vectors[0:@LENGTH@-1];integer i,fd;reg active=0;reg held=0;reg[PW+34:0]held_word;
always @(posedge clk)if(rst_n&&active)begin
 if(dut.push&&dut.read_en&&dut.write_address==dut.read_address)$fatal(1,"RAM same-address");
 if(dut.out_active&&dut.capture_bank==dut.out_bank)$fatal(1,"capture overwrites active frame");
 if(dut.latest_valid&&dut.capture_bank==dut.latest_bank)$fatal(1,"capture overwrites published frame");
 if(held&&(!m_valid||{m_frame_id,m_sof,m_eol,m_last,m_pixel}!==held_word))$fatal(1,"held output changed");
 held=m_valid&&!(ce&&m_ready);held_word={m_frame_id,m_sof,m_eol,m_last,m_pixel};
 $fdisplay(fd,"%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",i,ce,abort,cadence_tick,s_valid,s_ready,s_pixel,s_sof,s_eol,s_last,m_valid,m_ready,m_pixel,m_sof,m_eol,m_last,m_frame_id);
end
initial begin
 fd=$fopen("@TRACE@","w");$readmemh("@VECTORS@",vectors);repeat(3)@(negedge clk);rst_n=1;start_valid=1;@(negedge clk);start_valid=0;active=1;
 for(i=0;i<@LENGTH@;i=i+1)begin
 {ce,m_ready,cadence_tick,abort,s_valid,s_sof,s_eol,s_last,raw_pixel}=vectors[i][15:0];
 @(negedge clk);
 end
 active=0;if(!done_valid)$fatal(1,"no done");
 $display("COUNTERS %0d %0d %0d %0d %0d %0d ERROR %0d",published_count,output_count,dropped_count,repeated_count,underrun_count,tick_overrun_count,error_code);
 $fclose(fd);$finish;end
endmodule'''
def stimuli(w,h,num,den,input_every,interval=50,ticks=240,seed=77,stress=False,bad=False):
 rng=random.Random(seed);rows=[];pending=[];fid=0;pixels=w*h;end=interval*ticks
 for c in range(end+pixels*12+200):
  ce=rng.randrange(7)!=0 if c<end else True;ready=rng.randrange(4)!=0 if c<end else True;tick=(c%interval==0 and c<end);abort=c==end
  if tick and (c//interval)%input_every==0:
   pending.extend([(fid,p) for p in range(pixels)]);fid+=1
  valid=bool(pending) and c<end;sof=eol=last=val=0
  if valid:
   f,p=pending[0];val=(f*37+p*11)&255;sof=p==0;eol=p%w==w-1;last=p==pixels-1
   if bad and c>=end//2:sof=not sof;bad=False
   if ce:pending.pop(0)
  rows.append((int(ce)<<15)|(int(ready)<<14)|(int(tick)<<13)|(int(abort)<<12)|(int(valid)<<11)|(int(sof)<<10)|(int(eol)<<9)|(int(last)<<8)|val)
 return rows

def oracle(trace,w,h,num,den,expected_error):
 latest=None;capture=[];pub=out=drop=repeat=under=over=0;phase=0;active=None;pos=0;stopping=False;lastid=None;ids=[];visible=0;latest_selected=False;coverage=dict(due_publish=0,due_last_consume=0,triple_collision=0,publish_while_active=0)
 for line in trace.splitlines():
  c,ce,abort,tick,sv,sr,sd,sof,eol,last,mv,mr,md,msof,meol,mlast,mid=map(lambda v:int(v) if v.lstrip("-").isdigit() else -1,line.split())
  oldactive=active;launched=False;due=False
  if abort and ce:stopping=True
  if tick and not stopping:
   phase+=num
   if phase>=den:
    phase-=den;due=True
    if oldactive is not None:over+=1
    elif latest is None:under+=1
    else:
     active=(latest[0],list(latest[1]));pos=0;ids.append(active[0]);visible+=1;launched=True;latest_selected=True
     if lastid is not None and active[0]==lastid:repeat+=1
     lastid=active[0]
  if mv:
   assert active is not None,('unexpected output',c)
   fid,data=active
   assert (md,msof,meol,mlast,mid)==(data[pos],int(pos==0),int(pos%w==w-1),int(pos==w*h-1),fid),('output mismatch',c,pos,(md,msof,meol,mlast,mid),fid,data[pos])
   if ce and mr:
    pos+=1
    if pos==w*h:out+=1;active=None;pos=0
  if due and mv and ce and mr and mlast:coverage["due_last_consume"]+=1
  if sv and sr and ce:
   p=len(capture)
   if (sof,eol,last)!=(int(p==0),int(p%w==w-1),int(p==w*h-1)):
    stopping=True;continue
   capture.append(sd)
   if last:
    if due:coverage["due_publish"]+=1
    if oldactive is not None:coverage["publish_while_active"]+=1
    if due and mv and ce and mr and mlast:coverage["triple_collision"]+=1
    if latest is not None and not latest_selected and not launched:drop+=1
    latest=(pub,capture);pub+=1;capture=[];latest_selected=False
 assert active is None
 return [pub,out,drop,repeat,under,over],ids,coverage

def run(label,w=4,h=3,num=1,den=2,input_every=4,interval=50,ticks=240,seed=77,bad=False,mw=None,mh=None,custom_rows=None,pw=8):
 rows=custom_rows if custom_rows is not None else stimuli(w,h,num,den,input_every,interval,ticks,seed,bad=bad);mw=mw or w;mh=mh or h
 with tempfile.TemporaryDirectory(prefix='video_frc_') as td:
  p=Path(td);(p/'vectors.hex').write_text('\n'.join(f'{v:08x}' for v in rows)+'\n');tb=TB
  for key,value in dict(PW=pw,W=w,H=h,NUM=num,DEN=den,MW=mw,MH=mh,LENGTH=len(rows),TRACE=(p/'trace.txt').as_posix(),VECTORS=(p/'vectors.hex').as_posix()).items():tb=tb.replace('@'+key+'@',str(value))
  (p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',RTL,p/'tb.sv'],H,H/f'{label}_compile.log');out=execute(['vvp',p/'sim'],H,H/f'{label}_simulation.log');exp,ids,coverage=oracle((p/'trace.txt').read_text(),w,h,num,den,2 if bad else 9)
  import re
  m=re.search(r'COUNTERS (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) ERROR (\d+)',out);assert m,out;actual=list(map(int,m.groups()));assert actual==exp+[2 if bad else 9],(label,actual,exp)
 print(label,exp,'selected',len(ids));return dict(name=label,status='PASS',geometry=[w,h],pixel_w=pw,rate=[num,den],input_every=input_every,counters=exp,coverage=coverage,selected_frame_ids=ids,oracle='Independent Python complete-frame snapshots and rational phase; same-edge due uses previous published frame and pre-consume busy')
def main():
 rows=[run('30_to_60',num=1,den=2,input_every=4),run('60_to_30',num=1,den=4,input_every=2),run('24_to_30',num=1,den=4,input_every=5)]
 (H/'evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
