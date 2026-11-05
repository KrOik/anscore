# SPDX-License-Identifier: Apache-2.0
"""Independent bounded cycle reference using ordinary packet deques and lists."""
from collections import deque


def make_vectors(queues,depth,slots,tick_w,data_w,tag_w):
    tick_max=(1<<tick_w)-1;data_max=(1<<data_w)-1;tag_max=(1<<tag_w)-1
    rows=[];commands=launches=holds=guard_waits=resets=0
    state={}
    def clear():
        state.update(q=[deque() for _ in range(queues)],staging=[None]*slots,active=None,
                     running=False,slot=0,ticks=0,service=0,cursor=0,response=None)
    clear()
    def cycle(command=None,ready=1,accept=1,reset=False):
        nonlocal commands,launches,holds,guard_waits,resets
        if reset: clear();resets+=1
        defaults=[0,0,0,0,0,0,0,0,0]
        # command = op,queue,slot,duration,mask,cost,data,tag,enable
        c=defaults if command is None else list(command)
        valid=int(command is not None)
        op,qindex,slot,duration,mask,cost,data,tag,enable=c
        data &= data_max;tag &= tag_max
        cmd=[op,qindex,slot,duration,mask,cost,data,tag,enable]
        current_slot=state['slot'];ticks=state['ticks'];service=state['service']
        run=state['running'];response=state['response'];qs=state['q']
        gate=state['active'][current_slot][1] if state['active'] is not None else 0
        cready=int(not reset and response is None);fire=bool(valid and cready)
        out=[0]*13 if response is None else response
        rvalid=int(response is not None and not reset)
        if rvalid and not ready: holds+=1
        eligible=[q for q in range(queues) if (gate>>q)&1 and qs[q] and qs[q][0][0]<=ticks]
        if run and service==0 and any((gate>>q)&1 and qs[q] and qs[q][0][0]>ticks for q in range(queues)):
            guard_waits+=1
        choice=min(eligible,key=lambda q:(q-state['cursor'])%queues) if eligible else 0
        issue=bool(not reset and run and service==0 and accept and not fire and eligible)
        item=list(qs[choice][0]) if issue else [0,0,0]
        launch_fields=[choice,*item,current_slot,ticks] if issue else [0]*6
        cw=max(1,depth.bit_length())
        packed_levels=sum(len(qs[q])<<(q*cw) for q in range(queues))
        expected=[cready,rvalid,*out,int(issue),*launch_fields,int(run),current_slot,ticks,service,gate,packed_levels]
        # 13 input fields, followed by 28 expected fields.
        rows.append([int(not reset),valid,*cmd,ready,accept,*expected])
        if reset: return
        if response is not None and ready: state['response']=None
        if service: state['service']=service-1
        if run:
            if ticks==1:
                state['slot']=(current_slot+1)%slots
                state['ticks']=state['active'][state['slot']][0]
            else: state['ticks']=ticks-1
        if issue:
            qs[choice].popleft();state['service']=item[0]-1
            state['cursor']=(choice+1)%queues;launches+=1
        if fire:
            commands+=1
            valid_queue=qindex<queues
            head=list(qs[qindex][0]) if valid_queue and qs[qindex] else [0,0,0]
            reply=[op,0,qindex,slot,tag,len(qs[qindex]) if valid_queue else 0,
                   *head,current_slot,ticks,int(run),int(service!=0)]
            if op==0:
                if not valid_queue:reply[1]=2
                elif cost==0:reply[1]=4
                elif len(qs[qindex])==depth:reply[1]=5
                else:qs[qindex].append((cost,data,tag))
            elif op==1:
                if slot>=slots:reply[1]=3
                elif duration==0:reply[1]=4
                else:state['staging'][slot]=(duration,mask)
            elif op==2:
                if run or service:reply[1]=6
                elif any(entry is None for entry in state['staging']):reply[1]=7
                else:
                    state['active']=list(state['staging']);state['slot']=0
                    state['ticks']=state['active'][0][0];state['cursor']=0
            elif op==3:
                if not enable:state['running']=False
                elif run or service:reply[1]=6
                elif state['active'] is None:reply[1]=7
                else:
                    state['running']=True;state['slot']=0
                    state['ticks']=state['active'][0][0];state['cursor']=0
            elif op in (4,5):
                if not valid_queue:reply[1]=2
                elif op==5:
                    if not qs[qindex]:reply[1]=8
                    else:qs[qindex].popleft()
            else:reply[1]=1
            state['response']=reply
    tag_serial=0
    def command(op,q=0,slot=0,duration=0,mask=0,cost=0,data=0,enable=0,hold=2,accept=1):
        nonlocal tag_serial
        while state['response'] is not None:cycle(ready=1,accept=accept)
        tag_serial+=1
        payload=[op,q,slot,duration,mask,cost,data,tag_serial&tag_max,enable]
        cycle(payload,ready=0,accept=accept)
        # Hold a next request against a blocked response, without accepting it.
        for _ in range(hold):cycle([4,0,0,0,0,0,0,0,0],ready=0,accept=accept)
        cycle(ready=1,accept=accept)
    cycle(reset=True);cycle(reset=True)
    command(3,enable=1);command(2);command(6);command(7)
    command(0,q=0xffffffff,cost=1);command(4,q=queues);command(5,q=0)
    command(0,cost=0);command(1,slot=0xffffffff,duration=1);command(1,slot=0,duration=0)
    for slot in range(slots):
        duration=min(tick_max,[9,5,7,6][slot%4])
        mask=((1<<queues)-1) if slot==0 else (0 if slot%3==2 else 1<<(slot%queues))
        command(1,slot=slot,duration=duration,mask=mask)
    command(2)
    for q in range(queues):
        for index in range(depth):
            command(0,q=q,cost=1+(q+index)%max(1,min(5,tick_max)),data=(data_max^(q*17+index)))
        command(0,q=q,cost=1,data=0)
    command(3,enable=1)
    for clock in range(150+queues*depth*12):cycle(accept=int(clock%5 not in (0,1)))
    command(2);command(3,enable=1)
    command(1,slot=0,duration=min(tick_max,3),mask=0)
    for clock in range(25):cycle(accept=int(clock%3!=0))
    # An oversized head blocks only its own queue until explicitly dropped.
    if tick_max>9:
        command(0,q=0,cost=tick_max,data=data_max)
        if depth>1:command(0,q=0,cost=1,data=1)
        if queues>1:command(0,q=1,cost=1,data=2)
        for _ in range(30):cycle()
        command(4,q=0);command(5,q=0)
    for clock in range(50):cycle(accept=int(clock%4!=0))
    command(3,enable=0)
    while state['service']:cycle()
    command(2) # installs the staged closed first slot, preserving queued data
    command(0,q=0,cost=1,data=3)
    command(3,enable=1)
    for _ in range(30):cycle()
    # Reset with a held configuration reply invalidates every plan and queue.
    cycle([1,0,0,1,(1<<queues)-1,0,0,tag_serial&tag_max,0],ready=0)
    cycle(ready=0);cycle(reset=True);command(3,enable=1)
    for slot in range(slots):command(1,slot=slot,duration=tick_max,mask=(1<<queues)-1)
    command(2);command(0,cost=tick_max,data=data_max)
    command(3,enable=1,hold=3,accept=1)
    # For tick_max>1, launch occurred exactly at the full maximum-width window;
    # its non-preemptive service reservation is now live through this reset.
    cycle();command(3,enable=0);command(2);command(3,enable=1)
    cycle(reset=True);cycle(reset=True)
    command(4,q=0);command(5,q=0)
    for slot in range(slots):command(1,slot=slot,duration=1,mask=(1<<queues)-1)
    command(2);command(0,cost=1,data=0);command(3,enable=1)
    for _ in range(10):cycle()
    command(3,enable=0);command(4,q=0)
    return ''.join(' '.join(format(v,'x') for v in row)+'\n' for row in rows),dict(
        cycles=len(rows),commands=commands,launches=launches,response_holds=holds,
        guard_wait_cycles=guard_waits,reset_cycles=resets)
