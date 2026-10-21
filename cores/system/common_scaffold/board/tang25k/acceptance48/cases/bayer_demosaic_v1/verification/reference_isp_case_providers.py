"""ISP public wrapper cases, independent coordinate/matrix/gray-world references."""
from pathlib import Path
import random,sys
from case_provider_common import fixture_vectors
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2];SV=COMMON/'signal_video'
sys.path.insert(0,str(SV))
CASE_NAMES=['awb','ccm','bayer_demosaic']
def describe(name):
 sources=[SV/'rtl'/('cip_image_'+name+'.v')];params={}
 if name=='bayer_demosaic':
  params={'MAX_WIDTH':8,'RAW_BITS':8};sources += [COMMON/'image/pipelines/img_bayer_window_frontend_draft.v',COMMON/'image/window/img_window3x3_valid_draft.v',COMMON/'image/isp/img_isp_bayer_interpolate.v']
 else:
  sources += [SV/'rtl/cip_image_pointwise_frame_ctrl.v']
  sources += [COMMON/'image/isp'/(n+'.v') for n in (['img_isp_ccm'] if name=='ccm' else ['img_isp_awb_auto','img_isp_awb_stats','img_isp_awb_autogain','img_isp_awb_gain'])]
 return {'module':'cip_image_'+name,'data_w':24,'parameters':params,'sources':sources,'case_id':int.from_bytes({'awb':b'AWBA','ccm':b'CCMA','bayer_demosaic':b'BAYR'}[name],'big')}
def make_vectors(name):
 if name=='bayer_demosaic':
  from bayer_reference import fixtures
  return fixture_vectors(lambda p:fixtures(p,24,8),select=lambda i,r:i in [0,1,12,13,24,25,36,37] or i>=48)
 if name=='ccm':
  from ccm_reference import fixtures
  return fixture_vectors(lambda p:fixtures(p,24),11,select=lambda i,r:r[0]==1 or (r[1]<=8 and r[2]<=7))
 from pointwise_reference import fixtures
 # Keep complete command order: every accepted frame determines the next gains.
 return fixture_vectors(lambda p:fixtures(p,24,3))
