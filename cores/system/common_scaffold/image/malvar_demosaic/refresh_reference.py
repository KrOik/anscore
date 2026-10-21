"""Execute the actually downloaded mature function; preserve numeric fixtures, not copied source."""
from pathlib import Path
import ast,typing,json,hashlib,tempfile,numpy as np
from scipy.ndimage import convolve
from run_tests import HERE,PATTERNS,masks,oracle,execute
with tempfile.TemporaryDirectory(prefix='mhc_reference_') as tmp:
 d=Path(tmp);execute(['curl.exe','--ssl-revoke-best-effort','-L','--max-time','30','-sS','https://cdn.jsdelivr.net/gh/colour-science/colour-demosaicing@develop/colour_demosaicing/bayer/demosaicing/malvar2004.py','-o',d/'reference.py'],HERE,d/'fetch.log',timeout=45);source=(d/'reference.py').read_bytes()
assert hashlib.sha256(source).hexdigest()==json.loads((HERE/'references.json').read_text())[0]['sha256'],'upstream changed: review source before regenerating frozen fixtures'
tree=ast.parse(source.decode());fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='demosaicing_CFA_Bayer_Malvar2004')
module=ast.Module(body=[ast.ImportFrom(module='__future__',names=[ast.alias(name='annotations')],level=0),fn],type_ignores=[]);ast.fix_missing_locations(module)
def reference(a,pat,mode):
 env=dict(np=np,as_float_array=lambda x:np.asarray(x,dtype=float),ones=np.ones,tstack=lambda x:np.stack(x,axis=-1),cast=typing.cast,masks_CFA_Bayer=masks,convolve=lambda a,k:convolve(a,k,mode=mode))
 exec(compile(module,'downloaded_malvar2004_reference','exec'),env);return env['demosaicing_CFA_Bayer_Malvar2004'](a,pat)
rng=np.random.default_rng(731);rows=[]
for bits in [8,10,12]:
 for pat in range(4):
  a=rng.integers(0,1<<bits,(7,9));external=reference(a,PATTERNS[pat],'mirror');default=reference(a,PATTERNS[pat],'reflect');adapted=np.clip(np.floor(external+.5),0,(1<<bits)-1).astype(int);native=np.clip(np.floor(default+.5),0,(1<<bits)-1).astype(int);expected=oracle(a,pat,bits);assert np.array_equal(adapted,expected)
  d=np.abs(native-expected);assert d[2:-2,2:-2].max()==0
  rows.append(dict(name=f'colour_reference_b{bits}_{PATTERNS[pat]}',bits=bits,pattern=pat,cfa=a.tolist(),reflect101_reference=adapted.tolist(),native_reflect_max_error=int(d.max()),interior_error=0,adapted_error=0));print(rows[-1]['name'],rows[-1]['native_reflect_max_error'])
sha=hashlib.sha256(source).hexdigest();(HERE/'reference_fixtures.mem').write_text(json.dumps(dict(reference_source_sha256=sha,cases=rows),indent=2)+'\n')
(HERE/'references.json').write_text(json.dumps([dict(url='https://cdn.jsdelivr.net/gh/colour-science/colour-demosaicing@develop/colour_demosaicing/bayer/demosaicing/malvar2004.py',upstream='https://github.com/colour-science/colour-demosaicing/blob/develop/colour_demosaicing/bayer/demosaicing/malvar2004.py',bytes=len(source),sha256=sha,license='BSD-3-Clause; reference only, original RTL no source copied',executed=True,boundary='Mature function default scipy reflect; unmodified function executed with convolve backend mirror as explicit REFLECT101 adaptation, both results recorded'),dict(title='Malvar, He, Cutler (2004), High-Quality Linear Interpolation for Demosaicing of Bayer-Patterned Color Images',url='https://www.microsoft.com/en-us/research/publication/high-quality-linear-interpolation-for-demosaicing-of-bayer-patterned-color-images/',use='Paper attribution from retrieved reference; kernels independently verified against executable mature implementation')],indent=2)+'\n')
