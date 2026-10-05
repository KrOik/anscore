"""Independent float and exact Sobel/Scharr references (image y points down)."""
import math
def direction(gx,gy):
    ax,ay=abs(gx),abs(gy)
    if ax==ay==0:return 0,False
    if 128*ay<53*ax:q=0
    elif 128*ax<53*ay:q=2
    else:q=1
    if gx>=0 and gy>=0:d=q
    elif gx<0 and gy>=0:d=4-q
    elif gx<0 and gy<0:d=4+q
    else:d=(-q)%8
    return d,True

def gradients(image,scharr=False,l1=False,threshold=0,pad=0):
    h=len(image);w=len(image[0]);a,b=(3,10) if scharr else (1,2);out=[]
    kx=[[-a,0,a],[-b,0,b],[-a,0,a]];ky=[[-a,-b,-a],[0,0,0],[a,b,a]]
    for y in range(h):
      row=[]
      for x in range(w):
        gx=gy=0
        for iy in range(3):
          for ix in range(3):
            yy=y+iy-1;xx=x+ix-1
            v=0 if pad==0 and not (0<=yy<h and 0<=xx<w) else image[min(max(yy,0),h-1)][min(max(xx,0),w-1)]
            gx+=v*kx[iy][ix];gy+=v*ky[iy][ix]
        mag=abs(gx)+abs(gy) if l1 else math.isqrt(gx*gx+gy*gy)
        d,valid=direction(gx,gy)
        angle=math.degrees(math.atan2(gy,gx))%360 if valid else None
        error=abs((d*45-angle+180)%360-180) if valid else 0
        exact=abs(gx)+abs(gy) if l1 else math.hypot(gx,gy)
        row.append(dict(gx=gx,gy=gy,magnitude=mag,direction=d,direction_valid=valid,edge=mag>=threshold,float_magnitude=exact,direction_error_deg=error))
      out.append(row)
    return out

def pack(v,bits):
    g=bits+5;m=(1<<g)-1
    return (v['gx']&m)|((v['gy']&m)<<g)|(v['magnitude']<<(2*g))|(v['direction']<<(3*g))|(int(v['direction_valid'])<<(3*g+3))|(int(v['edge'])<<(3*g+4))
