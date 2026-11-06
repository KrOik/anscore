"""SPDX-License-Identifier: Apache-2.0. Independent list-based bounded matching oracle.
Executed only as a separately gated preparation child, never imported by runner.
"""
import argparse,hashlib,json,os
from pathlib import Path
PROFILES={'singleton':(1,1,1,1),'ragged':(5,9,7,4),'maximum':(32,32,32,32)}
BASE='05b9614c3962e9d4ae934c4b9c7bd315cc01aed4'

class Book:
    def __init__(self,capacity):self.capacity=capacity;self.rows=[]
    def command(self,op,order,sell,price,quantity,tag):
        result=[op,0,order,0,0,0,0,0,0,tag,0];fills=[]
        found=next((i for i,row in enumerate(self.rows) if row['id']==order),None)
        if op>3:result[1]=1
        elif op==3:self.rows=[]
        elif op==0:
            if quantity==0:result[1]=2
            elif found is not None:result[1]=3
            elif len(self.rows)==self.capacity:result[1]=4
            else:
                remain=quantity
                while remain:
                    eligible=[(i,row) for i,row in enumerate(self.rows) if row['sell']!=sell and
                        (row['price']>=price if sell else row['price']<=price)]
                    if not eligible:break
                    i,maker=min(eligible,key=lambda pair:((-pair[1]['price'] if sell else pair[1]['price']),pair[0]))
                    amount=min(remain,maker['quantity']);remain-=amount;maker['quantity']-=amount
                    fills.append([order,maker['id'],sell,maker['price'],amount,remain,maker['quantity'],len(fills),tag])
                    if not maker['quantity']:self.rows.pop(i)
                if remain:self.rows.append(dict(id=order,sell=sell,price=price,quantity=remain))
                result[3:9]=[sell,price,remain,quantity-remain,0,len(fills)]
        elif found is None:result[1]=5
        else:
            row=self.rows[found];result[3]=row['sell'];result[4]=row['price']
            if op==1:result[7]=row['quantity'];self.rows.pop(found)
            else:result[5]=row['quantity']
        result[10]=len(self.rows)
        assert len({x['id'] for x in self.rows})==len(self.rows)<=self.capacity
        assert all(x['quantity']>0 for x in self.rows)
        if op==0 and result[1]==0:assert result[5]+result[6]==quantity
        if result[1]:assert not fills
        return fills,result

def programs(profile):
    n,p,q,t=PROFILES[profile];pm=(1<<p)-1;qm=(1<<q)-1;tm=(1<<t)-1
    rows=[];serial=0
    def add(op,order=0,sell=0,price=0,qty=0):
        nonlocal serial
        rows.append((op,order,sell,price&pm,qty&qm,serial&tm));serial+=1
    def clear():add(3)
    clear();add(7);add(0,0,0,0,0);add(2,0);add(1,(1<<64)-1)
    add(0,0,0,0,qm);add(2,0);add(0,0,1,pm,qm);add(0,0,1,pm,0);add(1,0);add(2,0)
    add(0,(1<<64)-1,1,pm,qm);add(2,(1<<64)-1);add(1,(1<<64)-1);clear()
    # Exact capacity, replacement rejection, arbitrary removal and hole reuse.
    for i in range(n):add(0,100+i,1,pm,qm)
    add(0,9000,0,pm,qm);add(0,100,0,0,qm);add(0,100,0,0,0)
    add(2,100+n//2);add(1,100+n//2);add(0,9010,1,pm,qm)
    for i in [0,n-1,n//2]:add(1,100+i)
    for i in range(n):add(2,100+i)
    clear()
    if n>=2:
        # Better price beats earlier time; equality crosses; maker price executes.
        add(0,10,1,pm,qm)
        if n>=3:add(0,11,1,pm//2,qm)
        add(0,20,0,pm,qm);add(2,10);add(2,11);clear()
        add(0,30,0,0,qm)
        if n>=3:add(0,31,0,pm//2,qm)
        add(0,40,1,0,qm);add(2,30);add(2,31);clear()
        # Same price FIFO survives partial fills and a recycled physical slot.
        add(0,50,1,pm//2,qm)
        if n>=3:add(0,51,1,pm//2,qm)
        add(0,60,0,pm//2,1);add(2,50);add(2,51)
        add(0,61,0,pm//2,qm);add(2,50);add(2,51);clear()
        # Noncrossing residuals append, do not consume a wrong-side/price order.
        add(0,70,1,pm,qm);add(0,71,0,0,qm);add(2,70);add(2,71);clear()
        # A small maker sweep leaves a large resting residual.
        for i in range(n-1):add(0,200+i,1,pm-i%2,min(qm,2))
        add(0,300,0,pm,qm);add(2,300);clear()
    # Repeated exact full/empty cycles and maximum-width IDs/values, no RNG.
    for cycle in range(4):
        for i in range(n):add(0,(1<<63)+cycle*64+i,cycle&1,pm if cycle&1 else 0,qm)
        for i in reversed(range(n)):add(1,(1<<63)+cycle*64+i)
        add(2,(1<<63)+cycle*64);clear()
    return rows

def prepare(profile,out):
    out.mkdir(parents=True,exist_ok=False);book=Book(PROFILES[profile][0]);lines=[];fill_count=0;commands=programs(profile)
    for command in commands:
        fills,response=book.command(*command)
        # Header: 6 command fields, then 11 completion fields. Fill count is r_fills.
        formats=['d','x','d','x','x','x','d','d','x','d','x','x','x','x','d','x','d']
        lines.append(' '.join(format(v,f) for v,f in zip((*command,*response),formats)))
        for fill in fills:
            lines.append(' '.join(format(v,f) for v,f in zip(fill,['x','x','d','x','x','x','x','d','x'])))
        fill_count+=len(fills)
    vector=('\n'.join(lines)+'\n').encode()
    with (out/'vectors.txt').open('xb') as stream:stream.write(vector);stream.flush();os.fsync(stream.fileno())
    metadata=dict(schema='b49-price-time-preparation-v1',baseline_commit=BASE,profile=profile,
        parameters=PROFILES[profile],commands=len(commands),fills=fill_count,
        vectors_sha256=hashlib.sha256(vector).hexdigest(),final_live=len(book.rows),
        oracle='Plain insertion-ordered Python list; sort eligible orders by price and list position; no hash/RAM/list-link/FSM implementation',
        automatic_retry=False)
    with (out/'preparation.json').open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(metadata,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
    print('B49_ORDER_PREP_PASS commands=%d fills=%d'%(len(commands),fill_count),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--profile',required=True,choices=PROFILES);parser.add_argument('--out',required=True)
    args=parser.parse_args();prepare(args.profile,Path(args.out))
