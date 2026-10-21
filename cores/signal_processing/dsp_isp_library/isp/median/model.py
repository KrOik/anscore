"""Direct image indexing/order statistics; independent of RTL sorting topology."""
from statistics import median as float_median
def median_image(image,k=3,pad=0,bits=8,floating=False):
    if bits not in (8,10) or k not in (3,5) or pad not in (0,1) or not image or not image[0]:raise ValueError('unsupported configuration')
    h=len(image);w=len(image[0]);r=k//2
    if any(len(row)!=w for row in image) or any(type(v) is not int or not 0<=v<1<<bits for row in image for v in row):raise ValueError('image')
    answer=[]
    for y in range(h):
        row=[]
        for x in range(w):
            values=[]
            for dy in range(-r,r+1):
                for dx in range(-r,r+1):
                    yy,xx=y+dy,x+dx
                    v=0 if pad==0 and (yy<0 or yy>=h or xx<0 or xx>=w) else image[min(max(yy,0),h-1)][min(max(xx,0),w-1)]
                    values.append(v)
            row.append(float_median([float(v) for v in values]) if floating else sorted(values)[k*k//2])
        answer.append(row)
    return answer
