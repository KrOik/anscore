"""Actual hole-fill -> connected-components RTL, checked from raw input masks."""
from collections import deque
import hashlib
from pathlib import Path
import random
import tempfile

from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCES = [PACKAGE/'image/hole_fill/binary_hole_fill.sv',
           PACKAGE/'image/connected_components/img_connected_components.v']


def neighbors(index, width, height, eight):
    x,y = index % width,index // width
    for dy in (-1,0,1):
        for dx in (-1,0,1):
            if not (dx or dy) or (not eight and dx and dy):
                continue
            if 0 <= x+dx < width and 0 <= y+dy < height:
                yield (y+dy)*width+x+dx


def oracle(image, width, height, eight):
    exterior = {i for i,pixel in enumerate(image) if not pixel and
                (i % width in (0,width-1) or i // width in (0,height-1))}
    queue = deque(exterior)
    while queue:
        for n in neighbors(queue.popleft(),width,height,eight):
            if not image[n] and n not in exterior:
                exterior.add(n)
                queue.append(n)
    filled = [int(i not in exterior) for i in range(len(image))]
    labels = [0]*len(image)
    stats = []
    # Use the dual foreground connectivity: background4/foreground8 or vice versa.
    for index,pixel in enumerate(filled):
        if not pixel or labels[index]:
            continue
        label = len(stats)+1
        labels[index] = label
        members = [index]
        queue = deque([index])
        while queue:
            for n in neighbors(queue.popleft(),width,height,not eight):
                if filled[n] and not labels[n]:
                    labels[n] = label
                    members.append(n)
                    queue.append(n)
        xs = [n % width for n in members]
        ys = [n // width for n in members]
        stats.append((label,len(members),min(xs),max(xs),min(ys),max(ys)))
    return filled,labels,stats


def audit_oracle():
    import numpy as np
    from scipy.ndimage import binary_fill_holes, generate_binary_structure, label
    rng = random.Random(91603)
    checked = 0
    for width,height in ((1,1),(1,7),(7,1),(3,3),(11,9)):
        masks = [[0]*(width*height),[1]*(width*height)]
        masks += [[rng.randrange(2) for _ in range(width*height)] for _ in range(4)]
        for eight in (0,1):
            for image in masks:
                filled,labels,stats = oracle(image,width,height,eight)
                reference = binary_fill_holes(np.asarray(image).reshape(height,width),
                                              generate_binary_structure(2,2 if eight else 1))
                reference_labels,count = label(reference,generate_binary_structure(2,1 if eight else 2))
                assert filled == reference.astype(int).reshape(-1).tolist()
                assert labels == reference_labels.reshape(-1).tolist()
                assert len(stats) == count
                checked += 1
    return checked


def profile(width, height, eight, folder):
    rng = random.Random(16019+width*height+eight)
    n = width*height
    ring = [int(width>4 and height>4 and 1<=x<width-1 and 1<=y<height-1 and
                (x in (1,width-2) or y in (1,height-2)))
            for y in range(height) for x in range(width)]
    leak = ring.copy()
    if width>4 and height>4:
        leak[width+1] = 0
    images = [[0]*n,[1]*n,ring,leak]
    images += [[rng.randrange(2) for _ in range(n)] for _ in range(2)]
    images += [[(x+y)%2 for y in range(height) for x in range(width)]]
    expected = [oracle(image,width,height,eight) for image in images]
    all_stats = [item for _,_,stats in expected for item in stats]
    total_stats = len(all_stats)
    holes = [sum(a and not b for a,b in zip(fill,image))
             for image,(fill,_,_) in zip(images,expected)]
    if width>4 and height>4:
        assert holes[2] > 0
        assert holes[3] == (0 if eight else (width-4)*(height-4))
    label = f'{width}x{height}_bg{8 if eight else 4}'
    with tempfile.TemporaryDirectory(prefix='fill_components_') as temporary:
        td = Path(temporary)
        def mem(name,values):
            (td/name).write_text(''.join(f'{value:x}\n' for value in values),encoding='utf-8')
        mem('input.hex',[v for image in images for v in image])
        mem('filled.hex',[v for fill,_,_ in expected for v in fill])
        mem('labels.hex',[v for _,labels,_ in expected for v in labels])
        mem('stats.hex',[(l<<96)|(area<<64)|(xmin<<48)|(xmax<<32)|(ymin<<16)|ymax
                         for l,area,xmin,xmax,ymin,ymax in all_stats] or [0])
        mem('counts.hex',[len(stats) for _,_,stats in expected])
        mem('holes.hex',holes)
        tb = TB
        for key,value in dict(W=width,H=height,E=eight,F=len(images),S=max(1,total_stats)).items():
            tb = tb.replace('@'+key+'@',str(value))
        (td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],
                td,folder/f'{label}_compile.log')
        output = execute(['vvp',td/'sim'],td,folder/f'{label}_simulation.log',timeout=120)
        assert 'FILL_COMPONENTS PASS' in output,output
    print(label,len(images),'frames',n*len(images),'pixels',total_stats,'components PASS',flush=True)
    return dict(width=width,height=height,background_connectivity=8 if eight else 4,
                foreground_connectivity=4 if eight else 8,frames=len(images),
                pixels=n*len(images),components=total_stats,status='PASS')


TB = r'''
module tb;
localparam W=@W@,H=@H@,E=@E@,F=@F@,S=@S@,N=W*H;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,pixel=0,sv=0,sof=0,eol=0,lr=0,tr=0,ack=0;
wire sr,hpixel,hole,hv,hs,he,hr,hd,hbusy,lv,ls,le,tv,done,cerror;
wire[31:0] filled_count,area;wire[3:0] herror;wire[1:0] ccode;
wire[7:0] label,sl;wire[15:0] xmin,xmax,ymin,ymax;
binary_hole_fill #(.WIDTH(W),.HEIGHT(H),.CONNECT8(E)) fill(
 .clk(clk),.rst_n(rst_n),.ce(ce),.s_pixel(pixel),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_pixel(hpixel),.m_hole(hole),.m_valid(hv),.m_sof(hs),.m_eol(he),.m_ready(hr),
 .busy(hbusy),.done(hd),.filled_count(filled_count),.error_code(herror));
img_connected_components #(.WIDTH(W),.HEIGHT(H),.CONNECTIVITY(E?4:8),.LABEL_BITS(8),.MAX_LABELS(255)) ccl(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_data(hpixel),.s_valid(hv),.s_ready(hr),.s_sof(hs),.s_eol(he),
 .m_label(label),.m_valid(lv),.m_ready(lr),.m_sof(ls),.m_eol(le),
 .stats_valid(tv),.stats_ready(tr),.stats_label(sl),.stats_area(area),.stats_xmin(xmin),.stats_xmax(xmax),.stats_ymin(ymin),.stats_ymax(ymax),
 .done_valid(done),.done_ready(ack),.done_error(cerror),.error_code(ccode));
reg input_bits[0:F*N-1],filled[0:F*N-1];reg[7:0] labels[0:F*N-1];reg[103:0] stats[0:S-1];
integer counts[0:F-1],holes[0:F-1];
integer f=0,i,fp=0,lp=0,sp=0,target_stats=0,cycles=0;
reg hseen=0,take;reg[31:0] random_state=32'h68170529;
reg held_labels=0,held_stats=0;reg[9:0] label_payload;reg[103:0] stats_payload;
always @(posedge clk)begin
 cycles=cycles+1;if(cycles>1000000)$fatal(1,"timeout");
 if(rst_n)begin
  if(held_labels&&(!lv||{label,ls,le}!==label_payload))$fatal(1,"label stall stability");
  if(held_stats&&(!tv||{sl,area,xmin,xmax,ymin,ymax}!==stats_payload))$fatal(1,"stats stall stability");
  held_labels=lv&&(!ce||!lr);label_payload={label,ls,le};
  held_stats=tv&&(!ce||!tr);stats_payload={sl,area,xmin,xmax,ymin,ymax};
  if(ce&&hv&&hr)begin
   if(fp>=F*N)$fatal(1,"extra filled pixels");
   if(hpixel!==filled[fp]||hole!==(filled[fp]&&!input_bits[fp])||hs!==(fp%N==0)||he!==(fp%W==W-1))$fatal(1,"filled mask/markers %0d",fp);
   fp=fp+1;
  end
  if(ce&&lv&&lr)begin
   if(lp>=F*N)$fatal(1,"extra labels");
   if(label!==labels[lp]||ls!==(lp%N==0)||le!==(lp%W==W-1))$fatal(1,"label/markers %0d",lp);
   lp=lp+1;
  end
  if(ce&&tv&&tr)begin
   if(sp>=S)$fatal(1,"extra component");
   if({sl,area,xmin,xmax,ymin,ymax}!==stats[sp])$fatal(1,"component stats %0d",sp);
   sp=sp+1;
  end
  if(ce&&hd)begin hseen=1;if(filled_count!==holes[f]||herror)$fatal(1,"fill terminal");end
 end
end
task tick;begin
 @(negedge clk);#1;
 random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
 ce=random_state[0]|random_state[1];lr=random_state[2]|random_state[3];tr=random_state[4]|random_state[6];
end endtask
initial begin
 $readmemh("input.hex",input_bits);$readmemh("filled.hex",filled);$readmemh("labels.hex",labels);
 $readmemh("stats.hex",stats);$readmemh("counts.hex",counts);$readmemh("holes.hex",holes);
 repeat(3)@(negedge clk);#1;rst_n=1;
 for(f=0;f<F;f=f+1)begin
  i=0;hseen=0;
  while(i<N)begin
   pixel=input_bits[f*N+i];sof=i==0;eol=i%W==W-1;sv=1;
   @(posedge clk);take=ce&&sv&&sr;if(take)i=i+1;tick;
  end
  sv=0;target_stats=target_stats+counts[f];
  while(!hseen||!done)tick;
  if(fp!=(f+1)*N||lp!=(f+1)*N||sp!=target_stats||cerror)$fatal(1,"frame count/error");
  repeat(3)tick;
  ce=1;ack=1;@(negedge clk);#1;ack=0;
 end
 $display("FILL_COMPONENTS PASS frames=%0d pixels=%0d components=%0d",F,lp,sp);$finish;
end
endmodule
'''


if __name__ == '__main__':
    folder = evidence_dir('fill_components')
    audit_count = audit_oracle()
    results = [profile(w,h,eight,folder) for w,h in ((11,9),(1,7),(7,1)) for eight in (0,1)]
    write_json(folder/'results.json',dict(status='PASS',results=results,board_tested=False,
        oracle_scipy_fixture_count=audit_count,
        rtl_sha256={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in SOURCES}))
    print(folder,flush=True)
