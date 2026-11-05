"""SPDX-License-Identifier: Apache-2.0. Independent whole-datagram oracle."""
import random,struct
LENGTHS={b'A':36,b'F':40,b'E':31,b'C':36,b'X':23,b'D':19,b'U':35}
SESSION=b'ANSCORE001'
TOP=(1<<64)-1
def be(v,n):return v.to_bytes(n,'big')
def message(kind,seed=0):
    # Varied full-width fields; no implementation state or RAM addresses.
    r=random.Random(350000+seed);kind=kind.encode()
    head=kind+be(r.randrange(65536),2)+be(r.randrange(65536),2)+be(r.randrange(86400000000000),6)
    order=be(r.getrandbits(64),8);qty=be(r.getrandbits(32),4)
    price=be(r.randrange(2000000001),4);stock=b'ABCD    '
    if kind in [b'A',b'F']:
        return head+order+(b'B' if seed%2 else b'S')+qty+stock+price+(b'XYZ ' if kind==b'F' else b'')
    if kind in [b'E',b'C']:
        return head+order+qty+be(r.getrandbits(64),8)+((b'N' if seed%2 else b'Y')+price if kind==b'C' else b'')
    if kind==b'X':return head+order+qty
    if kind==b'D':return head+order
    return head+order+be(r.getrandbits(64),8)+qty+price
def packet(seq,messages=(),session=SESSION,control=None):
    return session+be(seq,8)+be(len(messages) if control is None else control,2)+b''.join(be(len(m),2)+m for m in messages)
def decode(body,sequence,tag,last):
    u=lambda a,n:int.from_bytes(body[a:a+n],'big')
    k=body[:1];row=[body[0],sequence,u(1,2),u(3,2),u(5,6),u(11,8),0,0,0,0,0,0,0,0,0,0,0,0,last,tag]
    # type seq locate tracking timestamp order new qty price stock attr match
    # sell printable price_valid stock_valid attr_valid match_valid last tag
    if k in [b'A',b'F']:
        row[7:11]=[u(20,4),u(32,4),u(24,8),u(36,4) if k==b'F' else 0]
        row[12]=int(body[19:20]==b'S');row[14:17]=[1,1,int(k==b'F')]
    elif k in [b'E',b'C']:
        row[7]=u(19,4);row[11]=u(23,8);row[13]=int(k==b'E' or body[31:32]==b'Y');row[17]=1
        if k==b'C':row[8]=u(32,4);row[14]=1
    elif k==b'X':row[7]=u(19,4)
    elif k==b'U':row[6:9]=[u(19,8),u(27,4),u(31,4)];row[14]=1
    return row
class Oracle:
    def __init__(self):self.session=None;self.next=0;self.ended=0
    def configure(self,session,nxt):self.session=session;self.next=nxt;self.ended=0
    def receive(self,data,keeps,tag,limit):
        good_header=len(data)>=20
        sess=data[:10] if good_header else bytes(10)
        seq=int.from_bytes(data[10:18],'big') if good_header else 0
        count=int.from_bytes(data[18:20],'big') if good_header else 0
        structural=not good_header or not all(keeps);bad_message=False;bodies=[]
        if good_header:
            offset=20
            if count not in [0,65535]:
                for _ in range(count):
                    if offset+2>len(data):structural=True;break
                    n=struct.unpack_from('!H',data,offset)[0];offset+=2
                    if offset+n>len(data):structural=True;break
                    b=data[offset:offset+n];offset+=n;bodies.append(b)
                    if b[:1] in LENGTHS:
                        bad_message|=len(b)!=LENGTHS[b[:1]]
                        if len(b)>19 and b[:1] in [b'A',b'F']:bad_message|=b[19:20] not in [b'B',b'S']
                        if len(b)>31 and b[:1]==b'C':bad_message|=b[31:32] not in [b'Y',b'N']
            structural|=offset!=len(data)
        if len(data)>limit:status=2
        elif structural:status=3
        elif bad_message:status=4
        elif self.session is None:status=1
        elif sess!=self.session:status=5
        elif seq<self.next:status=6
        elif seq>self.next:status=7
        elif self.ended and count not in [0,65535]:status=8
        elif count not in [0,65535] and seq+count>TOP:status=9
        else:status=0
        events=[]
        if status==0:
            selected=[(i,b) for i,b in enumerate(bodies) if b[:1] in LENGTHS]
            events=[decode(b,seq+i,tag,int(j==len(selected)-1)) for j,(i,b) in enumerate(selected)]
            if count==65535:self.ended=1
            elif count:self.next+=count
        return (status,int.from_bytes(sess,'big'),seq,count,len(events),self.next,self.ended,tag),events
def vectors(limit,tag_w):
    oracle=Oracle();lines=[];counts=dict(packets=0,events=0,configs=0,live_resets=0,bytes=0,statuses={})
    anchor=b'A'+bytes.fromhex('1234abcd0102030405061122334455667788')+b'S'+bytes.fromhex('01020304')+b'ABC     '+bytes.fromhex('12345678')
    assert len(anchor)==36
    assert decode(anchor,7,0,1)==[65,7,0x1234,0xabcd,0x010203040506,0x1122334455667788,0,0x01020304,0x12345678,int.from_bytes(b'ABC     ','big'),0,0,1,0,1,1,0,0,1,0]
    def cfg(n=1,session=SESSION):
        oracle.configure(session,n);lines.append(f'0 {int.from_bytes(session,"big")} {n}\n');counts['configs']+=1
    def send(data,keeps=None):
        tag=counts['packets']% (1<<tag_w);keeps=[1]*len(data) if keeps is None else keeps
        rsp,events=oracle.receive(data,keeps,tag,limit)
        lines.append('1 '+str(len(data))+' '+' '.join(map(str,rsp))+'\n')
        lines.extend(f'{v} {keep}\n' for v,keep in zip(data,keeps))
        lines.extend(' '.join(map(str,e))+'\n' for e in events)
        counts['packets']+=1;counts['events']+=len(events);counts['bytes']+=len(data)
        counts['statuses'][str(rsp[0])]=counts['statuses'].get(str(rsp[0]),0)+1
    send(packet(1,[message('D')])) # Fully valid datagram, but no configured epoch.
    cfg()
    send(packet(oracle.next,[anchor]))
    for k in 'AFECXDU':send(packet(oracle.next,[message(k,ord(k))]))
    send(packet(oracle.next,[b''])) # Legal zero-byte Mold message consumes one sequence.
    send(packet(oracle.next,[b'Z']))
    group=[message(k,i) for i,k in enumerate('AFECXDU')]
    if 20+sum(2+len(b) for b in group)+7<=limit:
        send(packet(oracle.next,[b'',group[0],b'Zabc',*group[1:],b'']))
    # Unsupported messages fill exactly the declared static packet storage.
    send(packet(oracle.next,[b'Z'+bytes((i%256 for i in range(limit-23)))]))
    send(packet(oracle.next,control=0))
    send(packet(oracle.next+2,[message('D')]))
    send(packet(oracle.next-1,[message('D')]))
    send(packet(oracle.next,[message('D')],b'OTHERSESS!'))
    # Replay correct sequence after each rejected future or old/session packet.
    send(packet(oracle.next,[message('A',999)]))
    send(packet(oracle.next,control=65535));send(packet(oracle.next,control=65535));send(packet(oracle.next,control=0))
    send(packet(oracle.next,[message('D')]))
    cfg(TOP);send(packet(TOP,[message('D')]))
    send(packet(TOP,control=0));send(packet(TOP,control=65535))
    cfg(TOP-1);send(packet(TOP-1,[message('D')]))
    send(packet(TOP,[b'',b'Z']))
    cfg(0);send(packet(0,[message('F',0)]))
    # Full first/last-field bit variation, arbitrary unsigned payload integers.
    for bit in range(0,64,7):
        b=bytearray(message('U',bit));b[11:19]=be(1<<bit,8);b[19:27]=be(TOP^(1<<bit),8)
        send(packet(oracle.next,[bytes(b)]))
    # Header/body truncation, count/length lies, extra byte, invalid public KEEP.
    base=packet(oracle.next,[message('A')])
    for cut in [1,9,10,17,18,19,20,21,22,23,40,len(base)-1]:send(base[:cut])
    send(base+b'\x00');send(base,keeps=[0]+[1]*(len(base)-1));send(b'\x00',[0])
    send(packet(oracle.next,control=0)+b'\x00');send(packet(oracle.next,control=65535)+b'\x00')
    bad_count=bytearray(base);bad_count[18:20]=be(2,2);send(bytes(bad_count))
    bad_len=bytearray(base);bad_len[20:22]=be(65535,2);send(bytes(bad_len))
    for k in 'AFECXDU':
        b=message(k)
        send(packet(oracle.next,[b[:-1]]));send(packet(oracle.next,[b+b'\x00']))
    for k in 'AF':
        b=bytearray(message(k));b[19]=ord('?');send(packet(oracle.next,[bytes(b)]))
    b=bytearray(message('C'));b[31]=ord('?');send(packet(oracle.next,[bytes(b)]))
    if limit>=100:
        # A good first event followed by a bad later event must leak nothing.
        b=bytearray(message('C'));b[31]=ord('?');send(packet(oracle.next,[message('D'),bytes(b)]))
    send(packet(oracle.next,[b'Z'+bytes(limit-22)])) # Exactly one byte over capacity.
    send(packet(oracle.next,[message('E')]))
    for i in range(18):
        k='AFECXDU'[i%7];b=message(k,300+i)
        send(packet(oracle.next,[b]))
    # Cancellation probes followed by explicit reconfiguration and a real fresh packet.
    for phase in range(4):
        cfg(1);data=packet(1,[message('F',phase)]) if phase!=3 else packet(1,control=0)
        lines.append(f'3 {phase} {len(data)}\n');lines.extend(f'{v} 1\n' for v in data)
        oracle=Oracle();counts['live_resets']+=1
        send(packet(1,[message('D')])) # Reset invalidates the configuration.
        cfg(1);send(packet(1,[message('F',phase+20)]))
    return ''.join(lines),counts
