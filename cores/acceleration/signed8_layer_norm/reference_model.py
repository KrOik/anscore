"""SPDX-License-Identifier: Apache-2.0. Integer specification, no RTL import."""
from math import isqrt

def rne(num,den):
    assert den>0
    q,r=divmod(num,den)
    return q+int(2*r>den or (2*r==den and q%2))

def rounded_sqrt(integer):
    q=isqrt(integer)
    # Compare squared half-integer boundary exactly, independent of recurrence.
    return q+int(4*integer>(2*q+1)**2)

def normalize(samples,epsilon,affine,frac):
    n=len(samples);s=sum(samples);q=sum(x*x for x in samples)
    central=n*q-s*s;radicand=central+n*n*epsilon
    root=rounded_sqrt(radicand << (2*(frac+2)))
    result=[]
    for x,(gamma,beta,shift) in zip(samples,affine):
        z=0 if root==0 else rne((n*x-s) << (2*frac+2),root)
        product=z*gamma;y=rne(product,1<<shift)+beta
        result.append((max(-128,min(127,y)),int(y< -128 or y>127),
                       int(product%(1<<shift)!=0),int(radicand==0)))
    return result

def input_quantize(samples,shift):
    result=[];clip=inexact=0
    for x in samples:
        q=rne(x,1<<shift);clip|=int(q< -128 or q>127)
        inexact|=int(x%(1<<shift)!=0);result.append(max(-128,min(127,q)))
    return result,clip,inexact
