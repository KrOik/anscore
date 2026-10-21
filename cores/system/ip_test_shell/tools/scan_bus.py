"""Transaction driver for the real scan mailbox format; backend is supplied.

The exchange callable must Capture-DR, shift exactly72 LSB-first bits and
Update-DR through a selected hard user instruction. No GPIO TAP or physical
backend is provided here. A timed-out write is never automatically retried.
"""
import time
import math
from scan_protocol import encode_command, decode_response


class ScanCsr:
    def __init__(self, exchange, timeout=2.0, max_polls=10000):
        if not math.isfinite(timeout) or not timeout>0 or type(max_polls) is not int or max_polls<1:
            raise ValueError('invalid poll bounds')
        self.exchange=exchange;self.timeout=timeout;self.max_polls=max_polls
        self.poisoned=False;self.exchanges=[]

    def _scan(self, command):
        response=self.exchange(command)
        self.exchanges.append(dict(command=command.hex(),response=response.hex()))
        return decode_response(response)

    def _poll(self, predicate, deadline):
        for _ in range(self.max_polls):
            if time.monotonic()>=deadline:break
            response=self._scan(bytes(9))
            if predicate(response):return response
        raise TimeoutError('scan CSR polling timed out; completion may be unknown')

    def access(self, address, data=None, strobe=15):
        if self.poisoned:raise RuntimeError('scan session uncertain; inspect/reset target before a new session')
        # Validate all fields before sending any request.
        encode_command(0,address,0 if data is None else data,write=data is not None,strobe=strobe)
        deadline=time.monotonic()+self.timeout
        idle=self._poll(lambda r:not r.busy,deadline)
        tag=(idle.tag+1)&255
        command=encode_command(tag,address,0 if data is None else data,write=data is not None,strobe=strobe)
        try:
            self._scan(command)  # Capture precedes Update: this is the old response.
            def completed(response):
                if response.command_error:raise RuntimeError('scan mailbox rejected command')
                return response.valid and not response.busy and response.tag==tag
            response=self._poll(completed,deadline)
        except Exception:
            self.poisoned=True
            raise
        if response.csr_error:raise RuntimeError('scan CSR target returned an error')
        return response.data
