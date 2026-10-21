"""WPR1/WPO1 external window protocol, independent raster oracle, cycle model.

The window-content oracle is infra/window/model.py: pure raster indexing with
no DUT state, banks or caches. The cycle oracle below is a faithful FSM model
of stream_window_padded + stream_window handshake timing (controls only; it
carries no memory contents), so a silicon timing divergence is also visible.
"""
import random, struct, sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
LIB=HERE.parents[1]
sys.path.insert(0,str(LIB/'infra/window'))
from model import windows

HDR=23
CAPTURE,REPLAY,DRAIN=0,1,2

def rec_bytes(k,dw):return (k*k*dw+2+7)//8

def make_packet(tag,config,pixels,stall=0):
    if not pixels or not 0<=stall<=7:raise ValueError('pixels/stall')
    if any(not 0<=v<=255 for v in pixels):raise ValueError('u8 pixels')
    if len(pixels)>65535:raise ValueError('count')
    return b'WPR1'+struct.pack('<IIHB',tag,config,len(pixels),stall)+bytes(pixels)

def oracle(frame,k,pad):
    """Per-output-position (lanes,eol,sof) from the independent raster model."""
    return windows(frame,k,pad)

def run_cycles(width,height,k,stall,nframes):
    """FSM-cycle model of the padded wrapper + VALID core handshakes.

    Mirrors the nonblocking-update order of both RTL modules (controls only;
    memory contents are irrelevant to timing). Returns the RUN cycle count the
    harness reports when the last output is accepted.
    """
    R=k//2;PW=width+k-1;PH=height+k-1;PIX=width*height
    total=PIX*nframes
    st=CAPTURE;x=y=rx=ry=oc=0;pend=0;rv=0
    ix=iy=0;ipend=0;mv=0;ipx=ipy=0
    sent=got=cyc=0
    while got<total:
        ordy=(cyc%8)>=stall
        adv_i=(not mv) or ordy
        rr=adv_i
        take_i=rv and rr
        adv_w=(not rv) or rr
        issue=(st==REPLAY) and adv_w
        take_w=(sent<total) and (st==CAPTURE)
        nst,nx,ny,nrx,nry,noc=st,x,y,rx,ry,oc
        # wrapper take block (CAPTURE only)
        if take_w:
            if x==width-1:
                nx=0;nst=REPLAY
                ny=0 if y==height-1 else y+1
            else:nx=x+1
            sent+=1
        # wrapper advance block
        npend,nrv=pend,rv
        if adv_w:
            npend=1 if issue else 0
            nrv=pend
            if issue:
                if rx==PW-1:
                    nrx=0
                    if ry==PH-1:nry=0;nst=DRAIN
                    else:
                        nry=ry+1
                        if R<=ry<R+height-1:nst=CAPTURE
                else:nrx=rx+1
        # wrapper output-count block (inner m_tvalid && m_tready)
        if mv and ordy:
            got+=1
            if oc==PIX-1:noc=0;nst=CAPTURE;nrx=0;nry=0
            else:noc=oc+1
        # inner VALID engine under adv_i
        if adv_i:
            nipend=1 if take_i else 0
            nmv=0
            if take_i:
                nipx,nipy=ix,iy
                if ix==PW-1:
                    nix=0;niy=0 if iy==PH-1 else iy+1
                else:nix=ix+1;niy=iy
            else:nix,niy,nipx,nipy=ix,iy,ipx,ipy
            if ipend and ipx>=k-1 and ipy>=k-1:nmv=1
            ipend,mv,ix,iy,ipx,ipy=nipend,nmv,nix,niy,nipx,nipy
        st,x,y,rx,ry,oc,pend,rv=nst,nx,ny,nrx,nry,noc,npend,nrv
        cyc+=1
        if cyc>400000:raise AssertionError('cycle model did not converge')
    return cyc

def records(report,n,k,dw):
    rb=rec_bytes(k,dw);mask=(1<<dw)-1;out=[]
    for i in range(n):
        r=int.from_bytes(report[HDR+i*rb:HDR+(i+1)*rb],'little')
        lanes=[(r>>(j*dw))&mask for j in range(k*k)]
        out.append((lanes,(r>>(k*k*dw))&1,(r>>(k*k*dw+1))&1))
    return out

def verify(report,tag,config,pixels,stall,width,height,k,dw,pad):
    n=len(pixels);pix=width*height
    if n%pix:raise AssertionError('packet is not whole frames')
    rb=rec_bytes(k,dw)
    if len(report)!=HDR+n*rb or report[:4]!=b'WPO1':raise AssertionError('report framing/count')
    rt,rc,cnt,flags,inc,outc,cycles=struct.unpack('<IIHBHHI',report[4:HDR])
    if (rt,rc,cnt,flags,inc,outc)!=(tag,config,n,0,n,n):raise AssertionError(('identity/flags/counters',rt,rc,cnt,flags,inc,outc))
    want=run_cycles(width,height,k,stall,n//pix)
    if cycles!=want:raise AssertionError(('cycles',cycles,want))
    actual=records(report,n,k,dw);bad=[]
    for f in range(n//pix):
        frame=[pixels[f*pix+y*width:f*pix+(y+1)*width] for y in range(height)]
        expected=oracle(frame,k,pad)
        for i,(lanes,eol,sof) in enumerate(expected):
            idx=f*pix+i;a=actual[idx]
            if a!=(lanes,eol,sof):
                x,y=i%width,i//width
                diffs=[(j,lanes[j],a[0][j]) for j in range(k*k) if lanes[j]!=a[0][j]]
                bad.append(dict(record=idx,x=x,y=y,frame=f,actual=a,expected=(lanes,eol,sof),lane_diffs=[(j%k,j//k,al,el) for j,el,al in diffs]))
    if bad:raise AssertionError(('window lanes',bad[:8]))
    return dict(status='PASS',tag=tag,records=n,frames=n//pix,replay_cycles=cycles,stall=stall)

# The exact 8x8 gray frame that fed win1 in the failing isp_chain8 board run
# (diagnostics/repaired_case00_left_edge.json): outputs at x=0,y in {2,3,4}
# read 0 on silicon instead of 95/84/84 -- a left-edge-zero signature.
FAILING_GRAY=[0,177,86,145,86,127,164,0,
              122,95,97,156,199,81,0,243,
              128,95,50,132,147,0,53,86,
              127,185,69,161,0,159,227,136,
              84,123,123,0,84,83,146,99,
              110,95,0,191,177,212,148,81,
              26,0,230,163,167,159,117,141,
              0,147,161,211,126,198,73,0]

def cases(width,height,dw=8):
    pix=width*height;rng=random.Random(7331+width*16+height);out=[]
    def frame(src):return [src(x,y) for y in range(height) for x in range(width)]
    if width==8 and height==8:
        out.append((0xACE80001,0,list(FAILING_GRAY),0))
        out.append((0xACE80002,0,list(FAILING_GRAY),7))
        # Three back-to-back copies of the failing frame: frame-boundary bank reuse.
        out.append((0xACE80003,0,list(FAILING_GRAY)*3,0))
    # Left/right-edge contrast: every left-edge window exposes column-0 reads.
    out.append((0xACE80100,0,frame(lambda x,y:0xF0-8*y if x==0 else (0x10+8*y if x==width-1 else 0)),0))
    out.append((0xACE80101,0,frame(lambda x,y:0xF0-8*y if x==0 else (0x10+8*y if x==width-1 else 0)),7))
    # Top/bottom row contrast.
    out.append((0xACE80102,0,frame(lambda x,y:0xE0-4*x if y==0 else (0x20+4*x if y==height-1 else 0)),1))
    # Diagonal zero scratch on bright field, then its complement.
    out.append((0xACE80103,0,frame(lambda x,y:0 if x==width-1-y or x==0 and y==0 else 200),0))
    out.append((0xACE80104,0,frame(lambda x,y:255 if x==width-1-y or x==0 and y==0 else 5),3))
    # Extremes and ramps.
    out.append((0xACE80105,0,[0]*pix,0))
    out.append((0xACE80106,0,[(1<<dw)-1]*pix,7))
    out.append((0xACE80107,0,frame(lambda x,y:(x+width*y)&0xFF),0))
    # Seeded random frames at several stalls, plus a two-frame random packet.
    for i,stall in enumerate((0,1,3,7)):
        out.append((0xACE80200+i,0,[rng.randrange(1<<dw) for _ in range(pix)],stall))
    out.append((0xACE80300,0,[rng.randrange(1<<dw) for _ in range(2*pix)],7))
    return out
