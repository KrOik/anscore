"""SPDX-License-Identifier: Apache-2.0. Original byte-oriented OUCH4.2 oracle.

No HDL or project helper imports. This is source until the exact review gate.
"""
FIELDS=(('timestamp',64),('token',112),('previous_token',112),('side',8),
        ('shares',32),('stock',64),('price',32),('time_in_force',32),('firm',32),
        ('display',8),('order_reference',64),('capacity',8),('sweep',8),
        ('minimum_quantity',32),('cross',8),('order_state',8),('bbo',8),
        ('reason',8),('event_code',8),('liquidity',8),('match',64))
LENGTHS={ord('S'):10,ord('A'):66,ord('U'):80,ord('C'):28,ord('E'):40,ord('J'):24}


def decode(data):
    kind=data[0] if data else 0
    fields={name:0 for name,width in FIELDS}
    status=0
    if not data:
        status=2
    elif kind not in LENGTHS:
        status=1
    elif len(data)!=LENGTHS[kind]:
        status=2
    elif kind==ord('S') and data[9] not in b'SE':
        status=3
    elif kind in b'AU' and (data[23] not in b'BSTE' or data[64] not in b'LD'):
        status=3
    elif kind==ord('C') and not 65<=data[27]<=90:
        status=3
    elif kind==ord('J') and not (65<=data[23]<=90 or 97<=data[23]<=122):
        status=3
    if status==0:
        def get(name,offset,size=1): fields[name]=int.from_bytes(data[offset:offset+size],'big')
        get('timestamp',1,8)
        if kind==ord('S'):
            get('event_code',9)
        else:
            get('token',9,14)
        if kind in b'AU':
            for name,offset,size in [('side',23,1),('shares',24,4),('stock',28,8),
                    ('price',36,4),('time_in_force',40,4),('firm',44,4),('display',48,1),
                    ('order_reference',49,8),('capacity',57,1),('sweep',58,1),
                    ('minimum_quantity',59,4),('cross',63,1),('order_state',64,1)]:
                get(name,offset,size)
            get('bbo',65 if kind==ord('A') else 79)
            if kind==ord('U'): get('previous_token',65,14)
        elif kind==ord('C'):
            get('shares',23,4);get('reason',27)
        elif kind==ord('E'):
            get('shares',23,4);get('price',27,4);get('liquidity',31);get('match',32,8)
        elif kind==ord('J'):
            get('reason',23)
    packed=0
    for name,width in FIELDS:
        assert 0<=fields[name]<(1<<width)
        packed=(packed<<width)|fields[name]
    return dict(status=status,type=kind,length=min(len(data),65535),event=packed,fields=fields)


def samples():
    tm=bytes.fromhex('fedcba9876543210')
    common=(b'NewToken000001'+b'T'+bytes.fromhex('f1234567')+b'AbC.D   '+
            bytes.fromhex('ffffffff')+bytes.fromhex('0001869f')+b'Ab12'+b'n'+
            bytes.fromhex('8123456789abcdef')+b'Oy'+bytes.fromhex('89abcdef')+b'ED')
    assert len(common)==56
    return [b'S'+tm+b'S',b'A'+tm+common+b'N',b'U'+tm+common+b'OldToken000001'+b'3',
            b'C'+tm+b'NewToken000001'+bytes.fromhex('f1234567')+b'Z',
            b'E'+tm+b'NewToken000001'+bytes.fromhex('ffffffff80000001')+b'3'+
                bytes.fromhex('fedcba9876543210'),b'J'+tm+b'NewToken000001'+b'x']
