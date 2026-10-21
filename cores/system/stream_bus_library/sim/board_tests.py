import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer,FallingEdge
from cocotb.queue import Queue
from codec import request,decode,status_fields,metric_fields
from board_reference import vectors,validate

BIT=24 # 12 cycles at2ns per cycle, accelerated simulation only.

@cocotb.test()
async def transport_regression(d):
    profile=int(os.environ.get('SYS_PROFILE','0'))
    d.uart_rx.value=1
    await Timer(1000,unit='ns')
    queue=Queue()
    async def rx():
        while True:
            await FallingEdge(d.uart_tx)
            await Timer(BIT*1.5,unit='ns')
            b=0
            for i in range(8):
                b|=int(d.uart_tx.value)<<i
                await Timer(BIT,unit='ns')
            assert int(d.uart_tx.value)==1,'TX stop bit'
            queue.put_nowait(b)
    cocotb.start_soon(rx())
    async def transaction(cmd,addr=0,payload=0,bad=False,status=0):
        packet=bytearray(request(cmd,addr,payload))
        if bad: packet[-1]^=1
        for byte in packet:
            for bit in [0]+[(byte>>i)&1 for i in range(8)]+[1]:
                d.uart_rx.value=bit
                await Timer(BIT,unit='ns')
        response=bytes([await queue.get() for _ in range(31)])
        return decode(response,cmd,addr,status)
    identity=await transaction(0); assert (identity>>8)&255==profile and identity>>32&0xffffffff==0x53595032
    await transaction(0,bad=True,status=1)
    await transaction(99,status=3)
    await transaction(1,256,0,status=2)
    # Native adapter regression covers all core values; UART smoke covers
    # load/run/status/read/metrics, CRC rejection and continuous replay.
    for core in ([15] if profile==0 else [0]):
        for seed,stall in [(1,0),(2,1)]:
            case=vectors(profile,core,seed)
            for i,a in enumerate(case['rows']): await transaction(1,i,a)
            await transaction(2,len(case['rows']),core|(stall<<8)|(len(case['expected'])<<16))
            status=None
            for _ in range(100):
                status=status_fields(await transaction(3))
                if status['done']: break
            assert status['done'] and not status['active'] and not status['error'],(case['name'],status)
            assert status['issued']==len(case['rows']) and status['captured']==len(case['expected'])
            actual=[await transaction(4,i) for i in range(status['captured'])]
            validate(case,actual)
            m=metric_fields(await transaction(5,0),await transaction(5,1))
            assert m['inputs']==status['issued'] and m['outputs']==status['captured']
            if 1<=profile<=7 or (profile==0 and core in [3,7,8,11,13,14,15]):
                assert m['errors']==0,(case['name'],m)
            if not stall and (1<=profile<=7 or (profile==0 and core in [3,7,8,13,14,15])):
                assert status['cycles']<=len(case['rows'])+4,(case['name'],'not full rate',status)
            d._log.info('RAW PASS %s seed=%d stalls=%d cycles=%d',case['name'],seed,stall,status['cycles'])
    # Length errors must end explicitly, without hanging the host.
    await transaction(2,257,0|(1<<16))
    status=status_fields(await transaction(3)); assert status['done'] and status['error']
