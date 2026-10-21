from pathlib import Path
import math,random
H=Path(__file__).resolve().parent
for r in range(1,16):
 rng=random.Random(0x4f5242)
 disk=[(x,y) for y in range(-r,r+1) for x in range(-r,r+1) if x*x+y*y<=r*r]
 pattern=[(*rng.choice(disk),*rng.choice(disk)) for _ in range(256)]
 def nearest(v):return int(math.floor(v+0.5)) if v>=0 else -int(math.floor(-v+0.5))
 words=[]
 for angle in range(16):
  c=math.cos(angle*math.pi/8);s=math.sin(angle*math.pi/8)
  for ax,ay,bx,by in pattern:
   q=[nearest(ax*c-ay*s),nearest(ax*s+ay*c),nearest(bx*c-by*s),nearest(bx*s+by*c)]
   words.append(sum((v&63)<<(18-6*i) for i,v in enumerate(q)))
 (H/f'pattern_r{r}.mem').write_text(''.join(f'{v:06x}\n' for v in words))
 (H/f'base_r{r}.hex').write_text(''.join(f'{sum((v&63)<<(18-6*i) for i,v in enumerate(pair)):06x}\n' for pair in pattern))
