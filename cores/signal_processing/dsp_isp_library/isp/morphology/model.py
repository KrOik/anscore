"""Independent 2D neighborhood morphology; no line-buffer or RTL state model."""
def stage(image,k,mask,dilate,pad):
    h=len(image);w=len(image[0]);r=k//2
    if k not in (3,5) or mask<=0 or mask >= 1<<(k*k) or pad not in (0,1):
        raise ValueError('illegal morphology configuration')
    result=[]
    for y in range(h):
        row=[]
        for x in range(w):
            samples=[]
            for ky in range(k):
                for kx in range(k):
                    if not ((mask>>(ky*k+kx))&1):continue
                    dy=ky-r;dx=kx-r
                    yy=y-dy if dilate else y+dy;xx=x-dx if dilate else x+dx
                    if pad==0 and not (0<=xx<w and 0<=yy<h):value=0
                    else:value=image[min(max(yy,0),h-1)][min(max(xx,0),w-1)]
                    samples.append(value)
            row.append(max(samples) if dilate else min(samples))
        result.append(row)
    return result

def morphology(image,k,mask,op,binary=False,pad=0):
    if op not in range(4):raise ValueError('operation')
    x=[[int(v!=0) if binary else v for v in row] for row in image]
    y=stage(x,k,mask,op in (1,3),pad)
    return stage(y,k,mask,op==2,pad) if op>=2 else y
