"""Binary UART wire format, no simulator dependencies."""
def crc8(data):
    c=0
    for b in data:
        c^=b
        for _ in range(8): c=((c<<1)^0x07)&255 if c&128 else (c<<1)&255
    return c

def request(cmd,address=0,payload=0):
    body=bytes([cmd])+address.to_bytes(2,'little')+payload.to_bytes(12,'little')
    return b'\xaa\x55'+body+bytes([crc8(body)])

def decode(data,cmd,address=0,expected_status=0):
    assert len(data)==31 and data[:2]==b'\x55\xaa',('response framing',len(data),data.hex())
    assert data[2]==cmd and int.from_bytes(data[4:6],'little')==address,'response identity'
    assert data[3]==expected_status,('response status',data[3])
    assert crc8(data[2:-1])==data[-1],'response CRC'
    return int.from_bytes(data[6:30],'little')

def status_fields(raw):
    return dict(error=bool(raw&1),done=bool(raw&2),active=bool(raw&4),issued=(raw>>16)&65535,
                captured=(raw>>32)&65535,cycles=(raw>>48)&0xffffffff,protocol_errors=(raw>>80)&0xffffffff)

def metric_fields(raw,aux):
    names=['inputs','outputs','input_stalls','output_stalls','latency_min','latency_max']
    m={n:(raw>>(32*i))&0xffffffff for i,n in enumerate(names)}
    m.update(cycles=aux&0xffffffff,max_output_gap=(aux>>32)&0xffffffff,errors=(aux>>64)&0xffffffff)
    return m
