import json
from pathlib import Path
from probe_external import ROOT,parse_decode,verify_decoded

results=[]
for name in ['uart_external_01','uart_external_02']:
    folder=ROOT/'artifacts/dsp_isp_20260925'/name
    data=parse_decode((folder/'decoded.txt').read_text())
    expected=(folder/'expected_packet.bin').read_bytes()
    assert data==(folder/'decoded.bin').read_bytes()
    assert verify_decoded(data,expected)==0
    bad=[('data',bytes([data[0]^1])+data[1:]),
         ('drop',data[:50]+data[51:]),
         ('duplicate',data[:50]+data[49:]),
         ('order',data[:50]+data[51:52]+data[50:51]+data[52:]),
         ('short',data[:64])]
    for label,mutated in bad:
        try:verify_decoded(mutated,expected)
        except ValueError:pass
        else:raise AssertionError('Accepted '+label)
    try:parse_decode('uart-1: ZZ\n')
    except ValueError:pass
    else:raise AssertionError('Accepted invalid decoder token')
    results.append(dict(session=name,bytes=len(data),passed=True,negative_checks=6))
out=ROOT/'artifacts/dsp_isp_20260925/probe_checker_audit.json'
with out.open('x') as f:json.dump(results,f,indent=2)
print('PASS both saved fresh captures; 12 data/order/count/parser mutations rejected')
