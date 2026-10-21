from test_timing import HERE
import subprocess,hashlib,json,re,html
urls=[('https://projectf.io/posts/video-timings-vga-720p-1080p/','640'),('https://cdn.jsdelivr.net/gh/projf/display_controller@master/rtl/display_timings.v','module')]
rows=[]
for url,needle in urls:
 data=subprocess.check_output(['curl.exe','-fsSL','--max-time','40',url]);text=data.decode()
 if url.endswith('/'):
  text=re.sub(r'<script.*?</script>|<style.*?</style>',' ',text,flags=re.S);text=html.unescape(re.sub(r'<[^>]*>',' ',text));text=re.sub(r'\s+',' ',text)
 i=text.find(needle);assert i>=0
 rows.append(dict(url=url,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpt=text[max(0,i-100):i+2200]))
(HERE/'references.json').write_text(json.dumps(rows,indent=2)+'\n')
