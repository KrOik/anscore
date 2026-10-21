"""Exact integer HWC model and deterministic complete-network fixture."""
import hashlib
import json


LAYERS=((28,28,1,4),(14,14,4,8))


def fixture():
    state=0x2505
    def random():
        nonlocal state
        state^=(state<<13)&0xffffffff;state^=state>>17;state^=(state<<5)&0xffffffff
        state&=0xffffffff
        return state
    return dict(schema='cnn25k_int8_v1',conv1=[random()%17-8 for _ in range(36)],
                conv2=[random()%17-8 for _ in range(288)],dense=[random()%17-8 for _ in range(3920)],
                bias1=[random()%513-256 for _ in range(4)],bias2=[random()%513-256 for _ in range(8)],
                bias3=[random()%513-256 for _ in range(10)])


def validate(model):
    if model.get('schema')!='cnn25k_int8_v1':raise ValueError('model schema')
    for weights,biases,n,outputs,terms in [('conv1','bias1',36,4,9),('conv2','bias2',288,8,36),('dense','bias3',3920,10,392)]:
        w,b=model[weights],model[biases]
        if len(w)!=n or len(b)!=outputs:raise ValueError('tensor shape: '+weights)
        if any(type(v) is not int or not -128<=v<=127 for v in w):raise ValueError('INT8 weights')
        if any(type(v) is not int or abs(v)+terms*128*128>2147483647 for v in b):raise ValueError('accumulator bound')


def conv(image,w,h,ci,co,weights,bias):
    acc=[]
    for y in range(h):
        for x in range(w):
            for o in range(co):
                total=bias[o]
                for i in range(ci):
                    for ky in range(3):
                        for kx in range(3):
                            yy,xx=y+ky-1,x+kx-1
                            if 0<=yy<h and 0<=xx<w:
                                total+=image[(yy*w+xx)*ci+i]*weights[((o*ci+i)*3+ky)*3+kx]
                acc.append(total)
    return acc


def pool(values,w,h,c):
    return [max(values[((2*y+dy)*w+2*x+dx)*c+i] for dy in range(2) for dx in range(2))
            for y in range(h//2) for x in range(w//2) for i in range(c)]


def infer(model,image):
    validate(model)
    if len(image)!=784 or any(type(v) is not int or not -128<=v<=127 for v in image):raise ValueError('signed28x28 input')
    taps={'input':list(image)};current=image
    for layer,(w,h,ci,co) in enumerate(LAYERS,1):
        acc=conv(current,w,h,ci,co,model['conv'+str(layer)],model['bias'+str(layer)])
        quant=[min(127,max(0,v)>>7) for v in acc]
        current=pool(quant,w,h,co)
        taps[f'conv{layer}_acc']=acc;taps[f'conv{layer}_quant']=quant;taps[f'pool{layer}']=current
    scores=[model['bias3'][o]+sum(v*model['dense'][o*392+i] for i,v in enumerate(current)) for o in range(10)]
    taps['scores']=scores
    taps['top3']=sorted(range(10),key=lambda i:(-scores[i],i))[:3]
    return taps


def model_hash(model):
    return hashlib.sha256(json.dumps(model,sort_keys=True,separators=(',',':')).encode()).hexdigest()
