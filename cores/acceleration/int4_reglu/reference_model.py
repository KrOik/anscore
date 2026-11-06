"""SPDX-License-Identifier: Apache-2.0. Integer equations, no RTL imports."""
def rne(n,shift):
    q,r=divmod(abs(n),1<<shift)
    q+=r*2>(1<<shift) or (r*2==(1<<shift) and q%2==1)
    return -q if n<0 else q

def quantize(n,scale,shift,zero):
    raw=n*scale;q=rne(raw,shift)+zero
    return max(-128,min(127,q)),int(not -128<=q<=127),int(raw%(1<<shift)!=0)

def project(x,xzero,weights,metadata):
    bias,scale,shift,zero=metadata
    return quantize(bias+sum((a-xzero)*b for a,b in zip(x,weights)),scale,shift,zero)

def reglu(x,xzero,gate_w,value_w,gate_meta,value_meta,out_meta):
    gate,gc,gi=project(x,xzero,gate_w,gate_meta)
    value,vc,vi=project(x,xzero,value_w,value_meta)
    y,clip,inexact=quantize(max(0,gate)*value,*out_meta)
    return y,clip,inexact,gc|vc,gi|vi,int(gate<=0)

def prefix(values,shift):
    quant=[quantize(v,1,shift,0) for v in values]
    return [v+128 for v,c,i in quant],int(any(c for v,c,i in quant)),int(any(i for v,c,i in quant))
