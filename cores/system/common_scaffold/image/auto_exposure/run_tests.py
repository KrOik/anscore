"""Independent integer specification plus closed-loop linear-sensor scenarios."""
import hashlib,json,pathlib,random,subprocess,tempfile,os,shutil
ROOT=pathlib.Path(__file__).resolve().parent
def main():
    lines=['configure(0);']; e,g=1,256; count=0; scenes={}
    def frame(total,n=1000,sat=0,overflow=False):
        nonlocal e,g,count
        bad=overflow or n==0 or sat>n or total>n*65535
        mean=0 if bad else total//n
        if not bad:
            direction=-1 if sat>10 or mean>131 else (1 if mean<125 else 0)
            if direction:
                delta=max(1,abs(mean-128)//4)
                # Specification: move first actuator toward its appropriate bound;
                # only a subsequent frame can move the second actuator.
                limit=1 if direction<0 else 200
                if e!=limit: e+=direction*min(abs(limit-e),8,delta)
                else:
                    limit=256 if direction<0 else 1024
                    g+=direction*min(abs(limit-g),16,delta)
        lines.append(f"frame_check(48'd{total},32'd{n},32'd{sat},1'b{int(overflow)},16'd{e},16'd{g},16'd{mean},1'b{int(bad)});")
        count+=1
        return mean
    for name,light in [('dim',2),('bright_step',5),('dark_step',1),('gain_required',0.25)]:
        history=[]
        for _ in range(400):
            # Sensor model integrates radiance * exposure * Q8 gain, no noise.
            m=min(65535,int(light*e*g/256));frame(m*1000);history.append((m,e,g))
        assert all(125<=v[0]<=131 for v in history[-20:]),(name,history[-20:])
        assert len(set(history[-20:]))==1,(name,'oscillation')
        scenes[name]={'final_mean':history[-1][0],'exposure':e,'gain':g,'stable_frames':20}
    for _ in range(150):frame(0)
    assert (e,g)==(200,1024)
    for _ in range(220):frame(65535000,sat=1000)
    assert (e,g)==(1,256)
    # Clipping dominates a dark mean, including at the exposure lower bound.
    frame(1000,sat=11)
    frame(0,n=0);frame(0,sat=1001);frame(65535001);frame(0,overflow=True)
    lines+=['cfg_target=0;configure(1);cfg_target=128;',
            'cfg_exposure_min=201;configure(1);cfg_exposure_min=1;',
            'cfg_gain_step=0;configure(1);cfg_gain_step=16;']
    frame(128000)
    rng=random.Random(92831)
    for _ in range(120):
        n=rng.randint(1,0xffffffff); m=rng.randrange(65536)
        frame(n*m,n=n,sat=0)
    # Largest legal sum, and one-bit overflow / saturated-count boundaries.
    frame(0xffffffff*65535,n=0xffffffff)
    frame(0xffffffffffff,n=0xffffffff)
    lines += ['cfg_exposure_min=10;cfg_exposure_max=20;cfg_gain_min=512;cfg_gain_max=600;',
              'cfg_target=1024;cfg_deadband=100;configure(0);',
              'if(exposure_lines<10 || exposure_lines>20 || gain_q8<512 || gain_q8>600) $fatal(1,"config clamp");',
              'frame_check(1024000,1000,0,0,exposure_lines,gain_q8,1024,0);']
    count+=1
    with tempfile.TemporaryDirectory(prefix='ae_test_') as tmp:
        p=pathlib.Path(tmp);(p/'vectors.vh').write_text('\n'.join(lines))
        commands=[['iverilog','-g2012','-I',str(p),'-s','tb','-o',str(p/'test.vvp'),str(ROOT/'img_ae_controller.v'),str(ROOT/'tb_img_ae_controller.sv')],['vvp',str(p/'test.vvp')]]
        log=''
        env=os.environ.copy()
        oss=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
        if oss.exists():env['PATH']=os.pathsep.join([str(oss/'bin'),str(oss/'lib'),env.get('PATH','')])
        for cmd in commands:
            cmd[0]=shutil.which(cmd[0],path=env['PATH']) or cmd[0]
            result=subprocess.run(cmd,capture_output=True,text=True,timeout=120,env=env)
            log+=result.stdout+result.stderr
            if result.returncode:raise RuntimeError(f'exit {result.returncode}: '+log)
        assert f'AE PASS checks={count}' in log,log
    result={'status':'PASS','frame_checks':count,'closed_loop':scenes,
            'rtl_sha256':hashlib.sha256((ROOT/'img_ae_controller.v').read_bytes()).hexdigest(),
            'board_tested':False,'log':log}
    (ROOT/'test_result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(log,end='')
if __name__=='__main__': main()
