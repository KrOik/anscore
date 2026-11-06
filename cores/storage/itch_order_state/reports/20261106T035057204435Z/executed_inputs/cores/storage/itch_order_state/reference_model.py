"""SPDX-License-Identifier: Apache-2.0. Ordinary Python order dictionary oracle."""
import random
STOCK=int.from_bytes(b'ANSCORE ','big');LOCATE=17;TOP=(1<<64)-1;QMAX=(1<<32)-1
def pack(fields,widths):
    result=0
    for value,width in zip(fields,widths):
        assert 0<=value<1<<width,(value,width)
        result=(result<<width)|value
    return result
class Book:
    def __init__(self,n,t):self.n=n;self.t=t;self.orders={};self.configured=0;self.faulted=0;self.locate=0;self.stock=0
    def apply(self,admin,op,locate,stock,order,new,sell,qty,price,sequence,tag):
        status=0;old=None;after=None;removed=0;added=0
        if admin:
            if op in [0,1]:
                self.orders.clear();self.faulted=0
                if op==0:self.configured=1;self.locate=locate;self.stock=stock
            elif op==3:self.faulted=1
            elif not self.configured:status=2
            elif self.faulted:status=3
            elif order not in self.orders:status=6
            else:old=(order,*self.orders[order]);after=old
        else:
            if not self.configured:status=2
            elif locate!=self.locate:status=1
            elif self.faulted:status=3
            elif op not in map(ord,'AFECXDU') or(op!=ord('D') and qty==0) or(op in [ord('A'),ord('F')] and stock!=self.stock)or(op==ord('U') and order==new):status=4
            elif op in [ord('A'),ord('F')]:
                if order in self.orders:status=5
                elif len(self.orders)==self.n:status=7
                else:self.orders[order]=(sell,price,qty);after=(order,sell,price,qty);added=1
            elif order not in self.orders:status=6
            else:
                side,p,q=self.orders[order]
                if op in map(ord,'ECX') and qty>q:status=8
                elif op==ord('U') and new in self.orders:status=5
                else:
                    old=(order,side,p,q)
                    if op in map(ord,'ECX'):
                        removed=qty
                        if qty==q:del self.orders[order]
                        else:self.orders[order]=(side,p,q-qty);after=(order,side,p,q-qty)
                    elif op==ord('D'):removed=q;del self.orders[order]
                    else:
                        removed=q;added=1;del self.orders[order]
                        self.orders[new]=(side,price,qty);after=(new,side,price,qty)
            if status in [4,5,6,7,8]:self.faulted=1
        # (id,side,price,qty) -> (valid,side,id,price,qty)
        record=lambda v:[1,v[1],v[0],v[2],v[3]] if v else [0]*5
        bid=sum(v[0]==0 for v in self.orders.values());ask=len(self.orders)-bid
        fields=[admin,op,status,order,sequence if not admin else 0,tag]+record(old)+record(after)+[int(removed!=0),removed,added,len(self.orders),bid,ask,self.configured,self.faulted]
        widths=[1,8,4,64,64,self.t,1,1,64,32,32,1,1,64,32,32,1,32,1,32,32,32,1,1]
        return pack(fields,widths),status
def vectors(n,t):
    model=Book(n,t);lines=[];rng=random.Random(360000+n);counts=dict(admin=0,events=0,statuses={},live_resets=0)
    serial=0
    def emit(admin,op,locate=LOCATE,stock=STOCK,order=0,new=0,sell=0,qty=0,price=0):
        nonlocal serial
        tag=((1<<(t-1))|serial) % (1<<t);sequence=((1<<63)+serial)&TOP;serial+=1
        expected,status=model.apply(admin,op,locate,stock,order,new,sell,qty,price,sequence,tag)
        if admin:lines.append(f'0 {op} {locate} {stock} {order} {tag}\n')
        else:lines.append(f'1 {op} {locate} {order} {new} {sell} {qty} {price} {stock} {sequence} {tag}\n')
        lines.append(f'{expected} {len(model.orders)}\n')
        lines.extend(f'{key} {side} {p} {q}\n' for key,(side,p,q) in sorted(model.orders.items()))
        counts['admin' if admin else 'events']+=1;counts['statuses'][str(status)]=counts['statuses'].get(str(status),0)+1
    def admin(op=0,order=0,locate=LOCATE,stock=STOCK):emit(1,op,order=order,locate=locate,stock=stock)
    def event(k,order=0,new=0,sell=0,qty=1,price=100,locate=LOCATE,stock=STOCK):emit(0,ord(k),order=order,new=new,sell=sell,qty=qty,price=price,locate=locate,stock=stock)
    def query(key):admin(2,key)
    event('A');query(0);admin(1);query(0);admin()
    # Hand-transparent lifecycle: C execution price differs from retained limit.
    event('A',0,qty=10,price=123);query(0)
    event('C',0,qty=3,price=999);query(0)
    event('U',0,new=TOP,sell=1,qty=12,price=456);query(0);query(TOP)
    event('X',TOP,qty=5);query(TOP);event('E',TOP,qty=7);query(TOP)
    event('F',TOP,sell=1,qty=QMAX,price=QMAX);event('D',TOP,qty=0);query(TOP)
    # Irrelevant instrument bypasses malformed fields and fault latch.
    event('?',qty=0,locate=LOCATE+1,stock=0)
    admin(3);event('A',locate=LOCATE+1);event('A');query(0);admin(1);event('A',qty=2,price=0);query(0);event('D')
    # Every normal failure preserves the complete dictionary; selected faults freeze.
    for k,extra in [('A',{'qty':0}),('F',{'stock':STOCK^1}),('?',{}),('U',{'new':0}),('E',{}),('C',{}),('X',{}),('D',{}),('U',{'new':1})]:
        admin(1);event(k,**extra);query(0);event('A');admin(1)
    for k in 'ECX':
        event('A',7,qty=2);event(k,7,qty=3);query(7);admin(1)
    event('A',7,sell=0);event('F',7,sell=1);query(7);admin(1)
    if n>=2:
        event('A',1,sell=0);event('A',2,sell=1);event('U',1,new=2,qty=2);query(1);query(2);admin(1)
    # Fill all capacity with deliberate XOR-fold collisions in one side.
    iw=max(1,(n-1).bit_length());keys=[(i<<iw)|i for i in range(n)]
    for side in [0,1]:
        admin(1)
        for i,key in enumerate(keys):event('A',key,sell=side,qty=(i%9)+1,price=QMAX if i%2 else 0)
        event('U',keys[0],new=TOP,sell=1-side,qty=QMAX,price=0x87654321)
        query(keys[0]);query(TOP)
        event('A',TOP-1,sell=1-side);query(TOP);event('D',TOP);admin(1)
    # All key bits and legal retired-ID reuse; input side is ignored on modifiers.
    for bit in [0,7,15,31,32,47,63]:
        key=1<<bit;event('F',key,sell=bit%2,qty=QMAX,price=(1<<(bit%32)))
        event('C',key,sell=1-bit%2,qty=1,price=QMAX);query(key);event('D',key)
    event('A',0);event('D',0);event('A',0,sell=1);event('D',0)
    # Bounded deterministic mixed stream; only complete logical operations.
    for _ in range(80):
        if model.faulted:
            query(rng.getrandbits(64));admin(1);continue
        choice=rng.randrange(6)
        if choice<2 and len(model.orders)<n:
            key=rng.getrandbits(64)
            event(rng.choice('AF'),key,sell=rng.randrange(2),qty=rng.choice([1,2,QMAX]),price=rng.getrandbits(32))
        elif model.orders:
            key=rng.choice(list(model.orders));side,p,q=model.orders[key]
            if choice==2:query(key)
            elif choice==3:event(rng.choice('ECX'),key,qty=rng.choice([1,q]),price=rng.getrandbits(32))
            elif choice==4:event('U',key,new=rng.getrandbits(64),qty=rng.choice([1,QMAX]),price=rng.getrandbits(32))
            else:event('D',key)
        else:query(rng.getrandbits(64))
    # CONFIG clears earlier state and changes the admitted symbol/locate.
    admin(0,locate=65535,stock=0);event('A');event('A',TOP,locate=65535,stock=0);query(TOP);admin()
    for phase in range(4):
        admin();
        if phase==1:event('A',0,qty=5)
        kind='U' if phase==1 else 'A';qty=0 if phase==3 else 3
        lines.append(f'2 {phase} {ord(kind)} {LOCATE} 0 {TOP} 0 {qty} 777 {STOCK} {TOP} 0\n')
        counts['live_resets']+=1;model=Book(n,t)
        query(0);event('A');admin();event('F',TOP,sell=1,qty=9,price=321);query(TOP)
    return ''.join(lines),counts
