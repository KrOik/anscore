"""SPDX-License-Identifier: Apache-2.0. Byte-map oracle, no controller model."""
class Reassembly:
    def __init__(self,capacity):self.capacity=capacity;self.reset()
    def reset(self):self.key=None;self.data={};self.end=None
    def command(self,op,key,offset,more,length,payload,header_bad=False):
        status=0;published=[]
        start=offset*8;stop=start+length
        if header_bad and op==0:status=8
        elif op==3:status=1
        elif op==1:self.reset()
        elif op==2:pass
        elif length<1 or stop>min(self.capacity,65515) or (more and length%8):status=2
        elif self.key is not None and self.key!=key:status=3
        elif self.key is not None and ((self.end is not None and
             (stop>self.end or (not more and stop!=self.end) or (more and stop>=self.end))) or
             (not more and self.data and stop<=max(self.data))):status=5
        elif any(i in self.data for i in range(start,stop)):status=4
        else:
            if self.key is None:self.key=key
            if not more:self.end=stop
            malformed=False
            for n,(byte,last) in enumerate(payload):
                self.data[start+n]=byte
                if bool(last)!=(n==length-1):malformed=True;break
            if malformed:status=6;self.reset()
            else:
                assert len(payload)==length and payload[-1][1]
                if self.end is not None and set(self.data)==set(range(self.end)):
                    published=[self.data[i]for i in range(self.end)]
        response=(status,int(bool(published)),int(self.key is not None),len(self.data),self.end or 0)
        if published:self.reset()
        return response,published

def make_header(key,offset,more,length,mode=0):
    src,dst,ident,protocol=key
    b=[0x45,0,(length+20)>>8,(length+20)&255,ident>>8,ident&255,
       (int(more)<<5)|(offset>>8),offset&255,64,protocol,0,0]
    b+=list(src.to_bytes(4,'big'))+list(dst.to_bytes(4,'big'))
    if mode==2:b[0]=0x46
    if mode==3:b[6]|=0x40
    if mode==4:b[8]=0
    if mode==5:b[2]=0;b[3]=20
    total=sum((b[i]<<8)|b[i+1]for i in range(0,20,2))
    while total>>16:total=(total&65535)+(total>>16)
    check=total^65535;b[10]=check>>8;b[11]=check&255
    if mode==1:b[11]^=1
    return int.from_bytes(bytes(b),'big')
