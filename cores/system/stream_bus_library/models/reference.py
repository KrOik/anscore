"""Functional reference algorithms. Never reads RTL or simulator results."""
def signed(value,width):
    value&=(1<<width)-1
    return value-(1<<width) if value&(1<<(width-1)) else value

def calibration(sample,gain,offset):
    exact=(signed(sample,24)*signed(gain,16)//16384)+signed(offset,24)
    clipped=min(max(exact,-8388608),8388607)
    return clipped&0xffffff,int(exact!=clipped)

def compact(value,keep):
    values=[(value>>(8*i))&255 for i in range(4) if keep&(1<<i)]
    return sum(byte<<(8*i) for i,byte in enumerate(values)),len(values)

def fault(value,mask,mode,enabled,phase):
    injected=bool(enabled and phase==0 and mode!=3)
    error=bool(enabled and phase==0 and mode==3)
    if injected:
        value=[value^mask,value&~mask,value|mask][mode]
    return value&0xffffffff,int(injected),int(error)

def aligned(rows):
    frames={}
    for epoch,channel,value in rows:
        frames.setdefault(epoch,{})[channel]=value
    return [(epoch,sum(frame.get(i,0)<<(32*i) for i in range(4)),
             sum((i not in frame)<<i for i in range(4))) for epoch,frame in sorted(frames.items())]

def trigger(samples,index,pre=4,post=4):
    return samples[max(0,index-pre):index+post+1]

def march_commands(depth):
    result=[]
    result.extend((True,a,0,None,0) for a in range(depth))
    for phase,descending,expected,value in [(1,False,0,0xffffffff),(2,False,0xffffffff,0),(3,True,0,0xffffffff),(4,True,0xffffffff,0)]:
        for address in (reversed(range(depth)) if descending else range(depth)):
            result.append((False,address,0,expected,phase))
            result.append((True,address,value,None,phase))
    result.extend((False,a,0,0,5) for a in range(depth))
    return result
