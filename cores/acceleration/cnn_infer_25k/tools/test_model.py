"""Independent flattened convolution/pooling cross-check; software evidence only."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
from model import fixture,validate,infer

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def reference(model,image):
    taps={'input':list(image)};current=image
    for layer,w,h,ci,co in ((1,28,28,1,4),(2,14,14,4,8)):
        weights=model[f'conv{layer}'];acc=[]
        # Lower each receptive field into one OIHW-ordered matrix row.
        for pos in range(w*h):
            y,x=divmod(pos,w);patch=[]
            for term in range(ci*9):
                channel,k=divmod(term,9);dy,dx=divmod(k,3)
                yy,xx=y+dy-1,x+dx-1
                patch.append(current[(yy*w+xx)*ci+channel] if 0<=yy<h and 0<=xx<w else 0)
            for o in range(co):
                acc.append(model[f'bias{layer}'][o]+sum(a*b for a,b in zip(patch,weights[o*ci*9:(o+1)*ci*9])))
        quant=[0 if a<0 else 127 if a>=128*128 else a//128 for a in acc]
        pooled=[0]*(w*h*co//4)
        for index,value in enumerate(quant):
            pos,c=divmod(index,co);y,x=divmod(pos,w)
            address=((y//2)*(w//2)+x//2)*co+c
            pooled[address]=max(pooled[address],value)
        taps[f'conv{layer}_acc']=acc;taps[f'conv{layer}_quant']=quant;taps[f'pool{layer}']=pooled
        current=pooled
    scores=model['bias3'].copy()
    for i,value in enumerate(current):
        for o in range(10):scores[o]+=value*model['dense'][o*392+i]
    taps['scores']=scores
    remaining=list(range(10));top=[]
    for _ in range(3):
        best=max(remaining,key=lambda i:(scores[i],-i));top.append(best);remaining.remove(best)
    taps['top3']=top
    return taps


def main():
    out=ROOT/'artifacts/cnn_infer_25k'/datetime.now(timezone.utc).strftime('model_test_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    files=[Path(__file__).resolve(),Path(__file__).with_name('model.py')]
    report=dict(status='FAIL',physical_measurement=False,rtl_verified=False,
                sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    try:
        model=fixture();cases=[[(i*37+11)%256-128 for i in range(784)],
                              [127 if (x+y)%2 else -128 for y in range(28) for x in range(28)],
                              [127 if i==406 else 0 for i in range(784)]]
        for image in cases:assert infer(model,image)==reference(model,image)
        zeros={k:([0]*len(v) if isinstance(v,list) else v) for k,v in model.items()}
        assert infer(zeros,cases[0])['top3']==[0,1,2]
        for key,value in [('conv1',[128]*36),('conv2',[0]),('bias3',[2147483647]*10)]:
            bad=dict(model);bad[key]=value
            try:validate(bad)
            except ValueError:pass
            else:raise AssertionError('accepted invalid '+key)
        report.update(status='PASS',network_cases=4,scope='independent integer software implementations; RTL and board pending')
        print('PASS complete CNN integer model:3 inputs,all layer taps,Top3 ties,range/overflow guards')
    except Exception as exc:
        report['reason']=str(exc);raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
