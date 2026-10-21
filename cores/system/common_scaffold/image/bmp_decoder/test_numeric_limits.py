from run_tests import *
def main():
 rows=[]
 for w,h in [(128,64),(256,1),(1,256),(256,256)]:
  data,pix=fixture(w,h,True,11,4);rows.append(run_case(f'numeric_{w}_{h}',data,pix,w,h,mw=w,mh=h))
 # Independently constructed 2x2 BGR, nonzero padding, nonstandard gap, BI_RGB size zero.
 pix=[0x123456,0xabcdef,0x070809,0xfefdfc];w=h=2;raw=bytes.fromhex('090807fcfdfe9988563412efcdab7766');off=61
 data=struct.pack('<2sIHHI',b'BM',off+len(raw),0,0,off)+struct.pack('<IiiHHIIiiII',40,w,h,1,24,0,0,123,456,0,0)+b'custom!'+raw
 assert list(Image.open(io.BytesIO(data)).convert('RGB').getdata())==[(v>>16,(v>>8)&255,v&255) for v in pix]
 rows.append(run_case('independent_bgr_padding',data,pix,w,h))
 good,_=fixture(2,2)
 for i,(mw,mh) in enumerate([(0,4),(4,0),(257,1),(1,257)]):rows.append(run_case('static_'+str(i),good,[],2,2,9,mw,mh))
 for name,off,value in [('offset_overflow',10,struct.pack('<I',0xfffffffe)),('signed_width',18,struct.pack('<I',0xffffffff)),('negative_height_limit',22,struct.pack('<i',-65))]:
  bad=good[:off]+value+good[off+len(value):];rows.append(run_case(name,bad,[],2,2,4 if name=='offset_overflow' else 3))
 (H/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=rows),indent=2)+'\n');print(json.dumps(rows))
if __name__=='__main__':main()

