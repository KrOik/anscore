from run_tests import HERE
import subprocess,hashlib,json
rows=[]
url='https://xilinx.github.io/Vitis_Libraries/vision/2022.1/overview.html'
data=subprocess.check_output(['curl.exe','-fsSL','--max-time','40',url]);text=data.decode();excerpts=[]
for needle in ['AXIvideo2xfMat', 'xfMat2AXIvideo', 'AXI4']:
 i=text.find(needle)
 if i>=0:excerpts.append(text[max(0,i-150):i+900])
assert len(excerpts)>=2
rows.append(dict(url=url,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpts=excerpts))
url='https://cdn.jsdelivr.net/gh/alexforencich/verilog-axis@master/rtl/axis_register.v'
data=subprocess.check_output(['curl.exe','-fsSL','--max-time','40',url]);text=data.decode();i=text.find('m_axis_tvalid_reg');assert i>=0
rows.append(dict(url=url,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpt=text[i:i+1800]))
(HERE/'references.json').write_text(json.dumps(rows,indent=2)+'\n')
