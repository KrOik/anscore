"""Independently decode six actual board UART JPEG frames; never edits fixtures."""
import argparse,hashlib,io,json,pathlib,sys
from PIL import Image
HERE=pathlib.Path(__file__).resolve().parent
DEFAULT=HERE.parents[1]/'board/tang25k/extension_acceptance/jpeg'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def require(ok,msg):
 if not ok:raise ValueError(msg)
def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('board_report',type=pathlib.Path);ap.add_argument('--fixtures',type=pathlib.Path,default=DEFAULT);ap.add_argument('--output',type=pathlib.Path,required=True);a=ap.parse_args()
 require(not a.output.exists(),'output already exists; preserve previous evidence')
 bound=[a.board_report.resolve(),pathlib.Path(__file__).resolve(),*(a.fixtures/n for n in ('simulation_gate.json','expected_uart.bin','pixels.hex'))]
 inputs={str(p.resolve()):sha(p) for p in bound};result=dict(status='FAIL',inputs_sha256=inputs,frames=[],scope='Independent Pillow decode of actual board UART; hold timing remains unproven')
 try:
  report=json.loads(a.board_report.read_text(encoding='utf-8'));gate=json.loads((a.fixtures/'simulation_gate.json').read_text(encoding='utf-8'));expected=(a.fixtures/'expected_uart.bin').read_bytes();pixels=bytes.fromhex((a.fixtures/'pixels.hex').read_text(encoding='ascii'))
  require(report['status']=='FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN','board report lacks qualified functional PASS')
  require(len(report['runs'])==3,'exactly three actual board runs required')
  require(len(expected)==999 and len(pixels)==234,'fixture byte counts differ')
  require(gate['status']=='SIMULATION_PASS_NOT_BOARD' and gate['uart_bytes']==999 and gate['uart_sha256']==hashlib.sha256(expected).hexdigest(),'simulation fixture UART binding')
  require([f['bytes'] for f in gate['frames']]==[411,588],'original frame boundaries changed')
  require(report.get('expected_sha256')==sha(a.fixtures/'expected_uart.bin'),'board expected binding differs')
  for index,run in enumerate(report['runs']):
   require(run['status']=='PASS' and run['programmer_returncode']==0 and run['detection']['returncode']==0,'board run not successful')
   actual=bytes.fromhex(run['uart_hex']);require(actual==expected,'actual UART differs from original 999-byte golden')
   require(run['received_bytes']==999 and run['uart_sha256']==hashlib.sha256(actual).hexdigest(),'actual UART accounting mismatch')
   offset=0
   for frame,golden in enumerate(gate['frames']):
    data=actual[offset:offset+golden['bytes']];offset+=golden['bytes'];digest=hashlib.sha256(data).hexdigest();require(digest==golden['sha256'],'actual frame SHA differs from golden')
    with Image.open(io.BytesIO(data)) as im:
     im.load();require(im.size==(13,9) and im.mode=='L','decoded dimensions or mode mismatch');decoded=im.tobytes()
    errors=[abs(x-y) for x,y in zip(decoded,pixels[frame*117:(frame+1)*117])];require(len(errors)==117 and max(errors)<=1,'actual decoded pixel error exceeds one')
    result['frames'].append(dict(run=index,frame=frame,status='PASS',bytes=len(data),sha256=digest,max_error=max(errors),mean_error=sum(errors)/117))
  require(all(sha(pathlib.Path(p))==h for p,h in inputs.items()),'inputs changed during decode');result['status']='PASS'
 except Exception as exc:result['error']=str(exc)
 a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(result['status'],a.output)
 if result['status']!='PASS':raise SystemExit(1)
if __name__=='__main__':main()
