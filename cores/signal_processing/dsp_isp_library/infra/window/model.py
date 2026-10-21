"""Pure raster reference: no DUT state, line banks or cycle implementation."""
def windows(frame,k,padding=-1):
    h=len(frame);w=len(frame[0]);r=k//2
    if padding not in (-1,0,1):raise ValueError('padding')
    ys=range(k-1,h) if padding<0 else range(h)
    xs=range(k-1,w) if padding<0 else range(w)
    result=[]
    for y in ys:
        for x in xs:
            pixels=[]
            for ky in range(k):
                for kx in range(k):
                    iy=y+ky-(k-1 if padding<0 else r)
                    ix=x+kx-(k-1 if padding<0 else r)
                    if padding==0 and not (0<=iy<h and 0<=ix<w):v=0
                    else:v=frame[min(max(iy,0),h-1)][min(max(ix,0),w-1)]
                    pixels.append(v)
            result.append((pixels,x==w-1,x==xs.start and y==ys.start))
    return result
