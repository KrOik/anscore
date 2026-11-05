# Exact bounded numerical definition

Let f be an unsigned8 image on a rectangular4- or8-neighbor pixel graph.
The first input transfer locks bright polarity b, Delta, P/Q and inclusive area
bounds. Work with g=f when b=1, otherwise g=255-f. This makes both polarities an
upper-component tree problem, and the output level is restored to f.

For each gray level l present in g, take the connected components of
{x:g(x)>=l}. A component having a pixel of gray l creates one canonical node v.
Its representative is the smallest raster index among its pixels of gray l.
Its level l(v) is l and its area a(v) is the full component size. The canonical
parent p(v) is the strict containing canonical component of smallest area. The
unique full-image root has p(root)=root. Parent gray levels strictly decrease;
parent area strictly increases. Equal-level pixels in one component create one
node and dense noncanonical positions contain zeros.

For each canonical v, let t(v) be the largest containing canonical component
with l(v)-Delta <= l(t(v)) <= l(v), including v itself. Define

```
n(v) = a(t(v)) - a(v)
q(v) = n(v) / a(v)
```

Delta is actual unsigned gray distance. It counts neither tree nodes nor
successive occupied levels. Levels with gaps are included exactly when their
distance is <=Delta. At the root, t=root and n=0. All fractions are exact;
0<=n<=N-1 and1<=a<=N. No division, float, rounding or tolerance is used in RTL.

Initialize stable(v)=true for every canonical node. Independently consider
every distinct child/parent pair (v,p) with l(v)-l(p)=1. Compare the two scores
using exact products n(v)*a(p) and n(p)*a(v). The larger score loses stability;
on equality the child loses. A node loses if any such comparison cancels it,
even when the other endpoint already lost another comparison. Gray gaps>1 do
not create a local comparison. An equality favors the parent in that pair; it
does not guarantee that parent is ultimately selected.

The final flag is precisely

```
canonical(v) && v!=root && stable(v)
  && min_area<=a(v)<=max_area
  && n(v)*Q < P*a(v)
```

The threshold is strict. Area limits are inclusive. Root exclusion is global,
including N1, constant frames and root score0. Diversity filtering is fixed0
(disabled). There is no symmetric two-sided area difference, ellipse fitting,
region-mask output, bounding box, subpixel interpolation or pixel-membership
stream. The dense flags identify canonical regions; consumers needing members
must reconstruct them from the source image/tree contract.

## Fixed hand witnesses (not executed evidence)

P3-D02 uses `[28,29,30,28,0,...]` and Delta1. Seed2 has area1 and top area2,
so score1/1. Its parent seed1 has area2 and top area4, so score2/2. Equality
cancels seed2. Seed1 can subsequently lose its own adjacent-level comparison.

P3-D03 contains63 zero pixels and a final255 pixel. Delta255 makes the bright
seed63 top the root, so n=63,a=1. Its parent gray gap255 creates no local pair
comparison. With P63/Q1, strict equality63/1 is rejected despite stability.

P1-L03 is `[0,10,30,90,30,10,0]`. Seed2 has gray30/area3 and parent seed1 has
gray10/area5. Delta20 includes that parent exactly, producing numerator2.
This checks a real gray gap20 while the local pair rule still skips the gap.

P3-D04 contains a2x2 bright block at x/y2..3. Canonical seed18 has area4,
numerator0 with Delta1, and is selected with min=max4 and threshold1/1.
P4-X01 is the full0..255 ramp and its root has area256, requiring CW9.
Every reset fresh frame has N-1 zero pixels followed by255, Delta8 and P/Q1/1:
root seed0 has areaN/num0/selected0; the last seed has area1/num0/selected1.

The future preparation checks only these fixed certificate obligations and
the fixed cases. Failure is terminal; it never searches replacement witnesses
or adds cases. The threshold-set/Fraction reference enumerates components at
present levels independently and uses strict set containment, rather than the
RTL's sorted activation/union-find dependency or ancestor-walk state machine.
