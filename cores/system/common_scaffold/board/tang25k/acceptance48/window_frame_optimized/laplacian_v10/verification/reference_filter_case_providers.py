"""Small filters/edges public-wrapper board profiles from independent 2-D oracles."""
from pathlib import Path
import sys,random
from case_provider_common import fixture_vectors
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2];SV=COMMON/'signal_video'
sys.path.insert(0,str(SV))
CASE_NAMES=['mean_filter','gaussian_filter','median_filter','sobel','prewitt','laplacian','morphology']
IDS=[b'MEAN',b'GAUS',b'MEDI',b'SOBL',b'PREW',b'LAPL',b'MORP']
def describe(name):
 sources=[SV/'rtl'/('cip_image_'+name+'.v')];params={'MAX_WIDTH':8};dataw=8
 if name=='morphology':sources += [SV/'rtl/cip_image_morph_frame.v'];params['MAX_HEIGHT']=6
 else:
  sources += [SV/'rtl/cip_image_window_filter_frame.v',COMMON/'image/window/img_window3x3_valid_draft.v']
  sources += [COMMON/'image/filters/rtl'/(n+'.v') for n in ['img_filter_kernel3x3','img_filter_stream_register','img_filter_mean9_rom','img_filter_median_sort3_segment']]
  if name in ['sobel','prewitt','laplacian']:
   params['MAG_SHIFT']=2;sources += [COMMON/'image/filters/rtl'/(n+'.v') for n in ['img_edge_gradient3x3','img_edge_laplacian3x3']]
 return {'module':'cip_image_'+name,'data_w':dataw,'parameters':params,'sources':sources,'case_id':int.from_bytes(IDS[CASE_NAMES.index(name)],'big')}
def make_vectors(name):
 if name in ['mean_filter','gaussian_filter','median_filter']:
  from window_filter_reference import fixtures
  op=['mean_filter','gaussian_filter','median_filter'].index(name)
  return fixture_vectors(lambda p:fixtures(p,8,op),select=lambda i,r:i in [0,5,6,17,30,35] or i>=36)
 if name in ['sobel','prewitt','laplacian']:
  from edge_reference import fixtures
  op=['sobel','prewitt','laplacian'].index(name)
  selected=[0,8,12,16,20,28,32,39,47,51,55,59,67,71]
  return fixture_vectors(lambda p:fixtures(p,8,op,2),select=lambda i,r:i in selected or i>=75)
 from run_morph_frame_tests import morphology
 rng=random.Random(4886);commands=[];inputs=[];outputs=[]
 def add(op,w,h,mask,error=0):
  image=[] if error else [rng.randrange(256) for _ in range(w*h)];out=[]
  if image:
   lo=morphology(image,w,h,mask,False);hi=morphology(image,w,h,mask,True)
   out=[lo,hi,morphology(lo,w,h,mask,True),morphology(hi,w,h,mask,False),[a-b for a,b in zip(hi,lo)]][op]
  values=[(op,0),(0x90+len(commands),4),(w,12),(h,28),(w,44),(h,60),(mask,76),(len(image),236),(len(out),252),(error,300),(len(inputs),302),(len(outputs),318)]
  commands.append(sum(v<<sh for v,sh in values))
  inputs.extend(v|(int(i==0)<<33)|(int(i%w==w-1)<<32) for i,v in enumerate(image));outputs.extend(v|(int(i==0)<<33)|(int(i%w==w-1)<<32) for i,v in enumerate(out))
 for op in range(5):
  for w,h,mask in [(1,1,511),(5,4,0xba),(8,6,511)]:add(op,w,h,mask)
 add(5,2,2,511,1);add(0,2,2,0,2)
 return commands,inputs,outputs,[],[]
