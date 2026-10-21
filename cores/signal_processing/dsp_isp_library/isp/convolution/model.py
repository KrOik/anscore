"""Independent exact-integer and floating-point 2D convolution references."""
def round_even(value,shift):
    if not 0<=shift<=31:raise ValueError('shift')
    sign=-1 if value<0 else 1
    q,r=divmod(abs(value),1<<shift)
    if shift and (r>(1<<(shift-1)) or r==(1<<(shift-1)) and q&1):q+=1
    return sign*q

def convolve(image,k,coeff,bias,shift,bits,pad,floating=False):
    if k not in (3,5) or bits not in (8,10) or pad not in (0,1) or len(coeff)!=k*k:
        raise ValueError('configuration')
    if not 0<=shift<=31 or not -(1<<31)<=bias<(1<<31) or any(not -2048<=c<=2047 for c in coeff):
        raise ValueError('configuration range')
    h=len(image);w=len(image[0]);r=k//2;result=[]
    for y in range(h):
        row=[]
        for x in range(w):
            total=float(bias) if floating else bias
            for ky in range(k):
                for kx in range(k):
                    yy=y-(ky-r);xx=x-(kx-r)
                    pixel=0 if pad==0 and not (0<=xx<w and 0<=yy<h) else image[min(max(yy,0),h-1)][min(max(xx,0),w-1)]
                    total+=pixel*coeff[ky*k+kx]
            row.append(max(0,min((1<<bits)-1,total/(1<<shift) if floating else round_even(total,shift))))
        result.append(row)
    return result
