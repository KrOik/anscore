from pathlib import Path
import subprocess,json,base64,hashlib
H=Path(__file__).resolve().parent
SOURCES=[('https://api.github.com/repos/dylanmsu/BT656_to_AXI4S/git/blobs/16ec4e21094aef6f495e1158dcae91355e931871',True,['Encode XYZ','result := "1"']),('https://cdn.jsdelivr.net/gh/torvalds/linux@v6.12/drivers/media/i2c/adv7180.c',False,['MEDIA_BUS_FMT_UYVY8_2X8','V4L2_MBUS_BT656'])]
def main():
 rows=[]
 for url,blob,needles in SOURCES:
  b=subprocess.check_output(['curl.exe','-fsSL','--connect-timeout','15','--max-time','35',url])
  if blob:b=base64.b64decode(json.loads(b)['content'])
  lines=b.decode().splitlines();hits=[i for i,l in enumerate(lines) if any(k in l for k in needles)]
  assert hits,'Reference lacks expected relevant material'
  rows.append(dict(url=url,sha256=hashlib.sha256(b).hexdigest(),excerpts=['\n'.join(lines[max(0,i-2):i+4]) for i in hits]))
 (H/'references.json').write_text(json.dumps(dict(sources=rows),indent=2)+'\n')
if __name__=='__main__':main()
