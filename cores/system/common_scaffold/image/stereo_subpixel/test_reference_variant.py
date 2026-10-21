"""Document intentional signed-rounding differences from the actually fetched OpenCV C++ expression."""
from pathlib import Path
import sys,json,random
from fractions import Fraction
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H))
from run_tests import reference
# Expression inspected in fetched OpenCV source, archived with SHA/excerpts in references.json.
OPENCV_FORMULA='((left-right)*DISP_SCALE+curvature)/(curvature*2)'

rng=random.Random(71);differ=0;max_delta=0
for _ in range(10000):
 left=rng.randrange(1,65536);right=rng.randrange(65536);curvature=left+right
 # Exactly mirror signed C++ division truncation toward zero in the retrieved source.
 numerator=(left-right)*16+curvature;opencv=(-1 if numerator<0 else 1)*(abs(numerator)//(2*curvature))
 ours=reference([left,0,right],[0,0,0],0,4)[2]
 delta=abs(ours-opencv);assert delta<=1;max_delta=max(max_delta,delta);differ+=delta!=0
sample=reference([3,0,7],[0,0,0],0,4)[2]
assert sample==-3
(H/'reference_variant_evidence.json').write_text(json.dumps({'result':'PASS','source':'actually retrieved OpenCV stereosgbm.cpp excerpts in references.json','comparisons':10000,'q4_max_difference_units':max_delta,'different_rounding_cases':differ,'counterexample':{'left':3,'best':0,'right':7,'rtl_fraction_oracle_q4':sample,'opencv_signed_cpp_expression_q4':-2},'scope':'Expression-level numeric-variant audit, not a claim of complete OpenCV StereoSGBM output equivalence'},indent=2)+'\n')
print('PASS mature-source expression audit:10000 cases, intentional signed rounding max1 Q4 unit difference')
