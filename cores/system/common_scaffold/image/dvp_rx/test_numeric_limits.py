from run_tests import *
def main():
 rows=[]
 for depth in [2,3,7,1024,4096]:
  for mode in [0,1]:rows.append(run_case(f'fifo_{depth}_{mode}',7,5,mode,flow=False,gaps=False,depth=depth))
 for be in [False,True]:
  samples,pix=wave(256,256,1,be,gaps=False,pixel_values=range(65536));rows.append(run_case(f'all_rgb565_{be}',256,256,1,be,flow=False,custom=(samples,pix)))
 for w,h in [(4096,1),(1,4096)]:rows.append(run_case(f'geometry_{w}_{h}',w,h,flow=False,gaps=False,mw=4096,mh=4096))
 for name,w,h,mw,mh,depth in [('width0',0,2,640,480,3),('height0',4,0,640,480,3),('widthover',641,2,640,480,3),('heightover',4,481,640,480,3),('maxwidth0',4,2,0,480,3),('maxheight4097',4,2,640,4097,3),('depth1',4,2,640,480,1),('depth4097',4,2,640,480,4097)]:
  rows.append(run_case(name,w,h,error=1,custom=([0],[0]),mw=mw,mh=mh,depth=depth))
 (H/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=rows),indent=2)+'\n');print(json.dumps(rows))
if __name__=='__main__':main()
