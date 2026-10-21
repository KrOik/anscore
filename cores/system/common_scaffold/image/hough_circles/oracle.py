"""Independent exhaustive center/radius search using actual skimage circle geometry."""
import numpy as np
from skimage.draw import circle_perimeter
def offsets(radius):
 rr,cc=circle_perimeter(0,0,radius,method='bresenham')
 return sorted(set(zip(map(int,cc),map(int,rr))))
def accumulator(edges,rmin,rmax):
 h,w=edges.shape;votes=np.zeros((rmax-rmin+1,h,w),dtype=np.int64)
 for k,r in enumerate(range(rmin,rmax+1)):
  ring=offsets(r)
  for y in range(h):
   for x in range(w):
    votes[k,y,x]=sum(bool(edges[y+dy,x+dx]) for dx,dy in ring if 0<=x+dx<w and 0<=y+dy<h)
 return votes
def oracle(edges,rmin,rmax,threshold,max_circles,center_nms,radius_nms):
 votes=accumulator(edges,rmin,rmax);output=[]
 for _ in range(max_circles):
  k,y,x=np.unravel_index(votes.argmax(),votes.shape);score=int(votes[k,y,x])
  if score<threshold:break
  r=int(k)+rmin;output.append((int(x),int(y),r,score))
  for kr,rr in enumerate(range(rmin,rmax+1)):
   if abs(rr-r)>radius_nms:continue
   for yy in range(edges.shape[0]):
    for xx in range(edges.shape[1]):
     if (xx-x)**2+(yy-y)**2<=center_nms**2:votes[kr,yy,xx]=0
 return output
def skimage_audit(edges,rmin,rmax):
 """skimage votes repeated symmetry points; remove only that known multiplicity."""
 from skimage.transform import hough_circle
 reference=hough_circle(edges,range(rmin,rmax+1),normalize=False,full_output=False)
 exact=accumulator(edges,rmin,rmax);h,w=edges.shape
 for k,r in enumerate(range(rmin,rmax+1)):
  rr,cc=circle_perimeter(0,0,r,method='bresenham');points=list(zip(map(int,cc),map(int,rr)))
  counts={p:points.count(p) for p in set(points)}
  for y in range(h):
   for x in range(w):
    correction=sum((count-1)*bool(edges[y+dy,x+dx]) for (dx,dy),count in counts.items() if count>1 and 0<=x+dx<w and 0<=y+dy<h)
    assert reference[k,y,x]-correction==exact[k,y,x],(r,x,y,reference[k,y,x],correction,exact[k,y,x])
 return {'radii':[rmin,rmax],'bins_checked':int(exact.size),'max_unique_votes':int(exact.max()),'max_skimage_raw_votes':float(reference.max()),'multiplicity_corrected_exact':True}
