"""Real binary_hole_fill -> contours_cell_edges RTL, checked as cell geometry."""
import hashlib
from pathlib import Path
import random
import tempfile

import numpy as np
import skimage
from scipy.ndimage import binary_fill_holes, generate_binary_structure
from skimage.measure import euler_number, label

from test_fill_components import oracle as fill_oracle
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCES = [PACKAGE/'image/hole_fill/binary_hole_fill.sv',
           PACKAGE/'image/contours/contours_cell_edges.v']
STEP = [(1,0),(0,1),(-1,0),(0,-1)]


def exposed_edges(mask, width, height):
    """Construct independent cell-side set; no vertex-quadrant RTL replication."""
    def fg(x,y):
        return 0 <= x < width and 0 <= y < height and mask[y*width+x]
    edges = set()
    for y in range(height):
        for x in range(width):
            if not fg(x,y):
                continue
            if not fg(x,y-1): edges.add((x,y,0))
            if not fg(x+1,y): edges.add((x+1,y,1))
            if not fg(x,y+1): edges.add((x+1,y+1,2))
            if not fg(x-1,y): edges.add((x,y+1,3))
    return edges


def verify_tokens(rows, mask, width, height):
    required = exposed_edges(mask,width,height)
    seen = set()
    start = end = None
    area = 0
    loops = holes = outers = net_area2 = 0
    local_index = 0
    for x,y,d,first,last,hole,reported_area,ci,ei in rows:
        assert 0 <= x <= width and 0 <= y <= height and 0 <= d < 4
        edge = (x,y,d)
        assert edge in required and edge not in seen, ('invalid/duplicate edge',edge)
        seen.add(edge)
        assert first == int(local_index == 0) and ci == loops and ei == local_index
        if first:
            assert start is None
            start = (x,y)
        else:
            assert end == (x,y), ('discontinuous loop',end,(x,y))
        dx,dy = STEP[d]
        end = (x+dx,y+dy)
        assert 0 <= end[0] <= width and 0 <= end[1] <= height
        area += x*end[1]-end[0]*y
        local_index += 1
        if last:
            assert end == start and area != 0, ('unclosed/degenerate loop',start,end,area)
            assert reported_area == area and hole == int(area < 0)
            loops += 1
            holes += area < 0
            outers += area > 0
            net_area2 += area
            start = end = None
            local_index = area = 0
        else:
            assert reported_area == 0 and hole == 0
    assert start is None and seen == required, ('incomplete coverage',len(seen),len(required))
    assert net_area2 == 2*sum(mask)
    array = np.array(mask,dtype=np.uint8).reshape(height,width)
    components = int(label(array,connectivity=1).max())
    euler = int(euler_number(array,connectivity=1))
    assert outers == components and holes == components-euler
    return dict(edges=len(rows),contours=loops,holes=holes,area=sum(mask),euler=euler)


def profile(width,height,eight,folder):
    rng = random.Random(14133+width*height+eight)
    n = width*height
    ring = [int(width>4 and height>4 and 1<=x<width-1 and 1<=y<height-1 and
                (x in (1,width-2) or y in (1,height-2)))
            for y in range(height) for x in range(width)]
    nested = ring.copy()
    if width>4 and height>4:
        nested[(height//2)*width+width//2] = 1
    leak = ring.copy()
    if width>4 and height>4:
        leak[width+1] = 0
    images = [[0]*n,[1]*n,ring,nested,leak,
              [(x+y)%2 for y in range(height) for x in range(width)]]
    images += [[int(rng.random()<density) for _ in range(n)]
               for density in (.15,.35,.5,.65,.8,.95)]
    masks = [fill_oracle(image,width,height,eight)[0] for image in images]
    for image,mask in zip(images,masks):
        actual = binary_fill_holes(np.array(image).reshape(height,width),
                                  structure=generate_binary_structure(2,2 if eight else 1))
        assert actual.ravel().astype(int).tolist() == mask
    if width>4 and height>4:
        original = np.array(ring).reshape(height,width)
        assert int(label(original,connectivity=1).max())-int(euler_number(original,connectivity=1)) == 1
        assert sum(masks[2]) > sum(ring), 'ring did not exercise hole filling'
    name = f'{width}x{height}_bg{8 if eight else 4}'
    with tempfile.TemporaryDirectory(prefix='fill_contours_') as temporary:
        td = Path(temporary)
        for filename,values in [('input',[v for a in images for v in a]),
                                ('expected',[v for a in masks for v in a])]:
            (td/(filename+'.hex')).write_text(''.join(f'{v:x}\n' for v in values))
        tb = TB
        for key,value in dict(W=width,H=height,E=eight,F=len(images)).items():
            tb = tb.replace('@'+key+'@',str(value))
        (td/'tb.sv').write_text(tb)
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],
                td,folder/f'{name}_compile.log')
        output = execute(['vvp',td/'sim'],td,folder/f'{name}_simulation.log',timeout=120)
        assert 'FILL_CONTOURS PASS' in output
        frames = [[] for _ in images]
        for line in (td/'tokens.txt').read_text().splitlines():
            frame,*row = map(int,line.split())
            assert 0 <= frame < len(images)
            frames[frame].append(row)
        results = [verify_tokens(rows,mask,width,height) for rows,mask in zip(frames,masks)]
    print(name,len(images),'frames',sum(r['edges'] for r in results),'edges PASS',flush=True)
    return dict(width=width,height=height,fill_background_connectivity=8 if eight else 4,
                contours_foreground_connectivity=4,frames=len(images),pixels=n*len(images),
                edges=sum(r['edges'] for r in results),contours=sum(r['contours'] for r in results),
                holes=sum(r['holes'] for r in results),status='PASS',frame_metrics=results)


TB = r'''
module tb;
localparam W=@W@,H=@H@,E=@E@,F=@F@,N=W*H,XW=$clog2(W+1),YW=$clog2(H+1),CW=$clog2(N+1),EW=$clog2(4*N+1);
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,pixel=0,sv=0,sof=0,eol=0,mr=0,dr=0;
wire sr,hpixel,hole,hv,hs,he,hr,hd,hbusy,mv,done,busy;
wire[31:0]filled_count;wire[3:0]herror;wire[1:0]error_code,dir;
wire[XW-1:0]x;wire[YW-1:0]y;wire first,last,ishole;wire signed[31:0]area2;
wire[CW-1:0]ci,foreground_count,contour_count;wire[EW-1:0]ei,edge_count;
wire[255:0]payload={x,y,dir,first,last,ishole,area2,ci,ei};
binary_hole_fill #(.WIDTH(W),.HEIGHT(H),.CONNECT8(E))fill(
 .clk(clk),.rst_n(rst_n),.ce(ce),.s_pixel(pixel),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_pixel(hpixel),.m_hole(hole),.m_valid(hv),.m_sof(hs),.m_eol(he),.m_ready(hr),
 .busy(hbusy),.done(hd),.filled_count(filled_count),.error_code(herror));
contours_cell_edges #(.WIDTH(W),.HEIGHT(H))contours(
 .clk(clk),.rst(!rst_n),.ce(ce),.s_pixel(hpixel),.s_valid(hv),.s_sof(hs),.s_eol(he),.s_ready(hr),
 .m_valid(mv),.m_ready(mr),.m_x(x),.m_y(y),.m_dir(dir),.m_contour_start(first),.m_contour_end(last),
 .m_hole(ishole),.m_area2(area2),.m_contour_index(ci),.m_edge_index(ei),
 .done_valid(done),.done_ready(dr),.error_code(error_code),.foreground_count(foreground_count),
 .contour_count(contour_count),.edge_count(edge_count),.busy(busy));
reg input_bits[0:F*N-1],expected[0:F*N-1];
integer f=0,i,transferred=0,cycles=0,tokens=0,closed=0,fd,fg_count=0,frame_tokens=0;
reg hseen=0,take,held=0,doneheld=0;reg[255:0]held_payload,held_status;
reg[31:0]random_state=32'h91bc37e9;
always @(posedge clk)begin
 cycles=cycles+1;if(cycles>4000000)$fatal(1,"timeout");
 if(rst_n)begin
  if(held&&(!mv||payload!==held_payload))$fatal(1,"OUT stall changed");
  if(doneheld&&(!done||{error_code,foreground_count,contour_count,edge_count}!==held_status))$fatal(1,"DONE stall changed");
  held=mv&&(!ce||!mr);held_payload=payload;
  doneheld=done&&(!ce||!dr);held_status={error_code,foreground_count,contour_count,edge_count};
  if(ce&&hv&&hr)begin
   if(transferred>=F*N||hpixel!==expected[transferred]||hs!==(transferred%N==0)||he!==(transferred%W==W-1))$fatal(1,"fill transfer %d",transferred);
   fg_count=fg_count+hpixel;transferred=transferred+1;
  end
  if(ce&&mv&&mr)begin
   $fdisplay(fd,"%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",f,x,y,dir,first,last,ishole,area2,ci,ei);
   tokens=tokens+1;frame_tokens=frame_tokens+1;if(last)closed=closed+1;
  end
  if(ce&&hd)begin if(herror)$fatal(1,"fill error");hseen=1;end
 end
end
task tick;begin
 @(negedge clk);#1;
 random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
 ce=random_state[0]|random_state[1];mr=random_state[2]|random_state[4];
end endtask
initial begin
 fd=$fopen("tokens.txt","w");$readmemh("input.hex",input_bits);$readmemh("expected.hex",expected);
 repeat(3)@(negedge clk);#1;rst_n=1;
 for(f=0;f<F;f=f+1)begin
  i=0;hseen=0;closed=0;fg_count=0;frame_tokens=0;dr=0;
  while(i<N)begin
   pixel=input_bits[f*N+i];sof=i==0;eol=i%W==W-1;sv=1;
   @(posedge clk);take=ce&&sv&&sr;if(take)i=i+1;tick;
  end
  sv=0;
  while(!done||!hseen)tick;
  if(error_code||foreground_count!=fg_count||edge_count!=frame_tokens||contour_count!=closed||transferred!=(f+1)*N)$fatal(1,"frame counters %d",f);
  repeat(5)tick;
  dr=1;@(posedge clk);while(!ce)begin tick;@(posedge clk);end
  tick;dr=0;
 end
 $fclose(fd);$display("FILL_CONTOURS PASS frames=%0d pixels=%0d edges=%0d",F,transferred,tokens);$finish;
end
endmodule
'''


if __name__ == '__main__':
    folder = evidence_dir('fill_contours')
    results = [profile(w,h,eight,folder) for w,h in ((9,9),(3,3),(1,7),(7,1),(1,1)) for eight in (0,1)]
    write_json(folder/'results.json',dict(status='PASS',results=results,board_tested=False,
        skimage_version=skimage.__version__,reference='independent cell exposed edges, ordered continuity, closure, signed shoelace, FG4/BG8 Euler',
        test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        fill_oracle_sha256=hashlib.sha256(Path(__file__).with_name('test_fill_components.py').read_bytes()).hexdigest(),
        rtl_sha256={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in SOURCES}))
    print(folder,flush=True)
