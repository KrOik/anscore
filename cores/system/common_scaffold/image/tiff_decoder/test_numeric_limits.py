from run_tests import *
def main():
 rows=[]
 for w,h,mode,mw,mh,mb in [(1,1,0,16,12,4096),(16,12,2,16,12,4096),(32,24,2,32,24,4096),(256,1,1,256,1,4096),(1,256,2,1,256,4096)]:
  for big in [False,True]:
   data,pix=fixture(w,h,mode,big,rps=max(1,h//3),short=True);rows.append(run_case(f'limit_{w}_{h}_{mode}_{big}',data,pix,w,h,mode,mw=mw,mh=mh,mb=mb))
 good,pix=fixture()
 for cap in [4096,8192]:
  data=good+bytes(cap-len(good));rows.append(run_case(f'capacity_{cap}',data,pix,7,5,mb=cap))
 rows.append(run_case('overflow',good+bytes(4097-len(good)),[],7,5,error=3))
 for name,mw,mh,mb in [('width0',0,12,4096),('height257',16,257,4096),('buffer63',16,12,63),('buffer8193',16,12,8193)]:
  rows.append(run_case(name,good,[],7,5,error=10,mw=mw,mh=mh,mb=mb))
 report=dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=rows);(H/'numeric_evidence.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
