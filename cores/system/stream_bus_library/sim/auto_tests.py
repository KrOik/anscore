import os
import cocotb
from cocotb.triggers import Timer,FallingEdge,with_timeout
from auto_check import check
from codec import crc8

@cocotb.test()
async def jtag_load_raw_uart(d):
    p=int(os.environ['SYS_PROFILE']); frames=[]
    d.uart_rx.value=1
    while True:
        body=[]
        for _ in range(31):
            await with_timeout(FallingEdge(d.uart_tx),5,timeout_unit='ms')
            await Timer(36,unit='ns'); b=0
            for i in range(8):
                b|=int(d.uart_tx.value)<<i; await Timer(24,unit='ns')
            assert int(d.uart_tx.value)==1
            body.append(b)
        packet=bytes(body); assert packet[:2]==b'\x55\xaa' and crc8(packet[2:-1])==packet[-1]
        frames.append((packet[2],int.from_bytes(packet[4:6],'little'),int.from_bytes(packet[6:30],'little')))
        if packet[2]==0x85 and packet[4]==1: d._log.info('AUTO case=%d capture complete',packet[5])
        if packet[2]==0x86: break
    result=check(p,frames)
    d._log.info('AUTO RAW PASS profile=%d cases=%d responses=%d',p,len(result),sum(len(r['raw']) for r in result))
