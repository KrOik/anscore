from run_tests import *
def main():
 frozen=hashes();w,h,dw=128,8,24;values=[(i*131071)^0xabcdef for i in range(4*w*h)]
 tb=TB.replace('@W@',str(w)).replace('@H@',str(h)).replace('@DW@',str(dw))
 tb=tb.replace('ce=rng[0]|rng[2];m_ready=rng[1];','ce=1;m_ready=1;')
 tb=tb.replace('if(N>4&&offhand==0)','if(0)')
 tb=tb.replace('if(i==0)begin ce=0;tick;end','')
 tb=tb.replace('integer f,i,got=', 'integer prevax=0,prevpix=0;integer f,i,got=')
 tb=tb.replace('ax=ax+1;', 'if(ax%N!=0&&cyc-prevax!=1)$fatal(1,"AXI throughput bubble");prevax=cyc;ax=ax+1;')
 tb=tb.replace('got=got+1;', 'if(got%N!=0&&cyc-prevpix!=1)$fatal(1,"pixel throughput bubble");prevpix=cyc;got=got+1;')
 with tempfile.TemporaryDirectory(prefix='axi_video_throughput_') as tmp:
  p=Path(tmp);(p/'pixels.hex').write_text('\n'.join(f'{v&0xffffff:x}' for v in values));(p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log');print(out)
 assert hashes()==frozen
 (HERE/'throughput_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,width=w,height=h,data_width=dw,frames=4,pixels=4096,axi_initiation_interval=1,pixel_initiation_interval=1,output=out),indent=2)+'\n')
if __name__=='__main__':main()
