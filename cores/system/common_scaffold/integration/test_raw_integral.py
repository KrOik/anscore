"""Actual optical-black correction -> persistent rectangle-statistics RTL chain."""
import hashlib
import random
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

TB = r'''module tb;
localparam W=9,H=7,N=W*H,F=4,Q=85;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,sv=0,sof=0,eol=0,last=0,ack=0,qv=0,rr=0;
reg[11:0]raw;reg[1:0]pattern;reg[15:0]x0,y0,x1,y1;
wire br,sr,bv,ir,bs,be,bl,bd,berr,idr,idone,ierr,fvalid,qr,rv,rerr;
wire[11:0]braw;wire[7:0]bc;wire[3:0]ic,rc;
wire[31:0]rsum,rcount,accepted;wire[39:0]rsq;
raw_black_level #(.WIDTH(W),.HEIGHT(H),.BITS(12)) black(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(br),
.cfg_auto(1'b1),.cfg_pattern(pattern),.cfg_black_levels(48'b0),.cfg_target_pedestal(12'd11),
.cfg_roi_x(16'd0),.cfg_roi_y(16'd0),.cfg_roi_width(16'd9),.cfg_roi_height(16'd2),.abort(1'b0),
.s_data(raw),.s_valid(sv),.s_ready(sr),.s_sof(sof),.s_eol(eol),.s_last(last),
.m_data(braw),.m_valid(bv),.m_ready(ir),.m_sof(bs),.m_eol(be),.m_last(bl),
.done_valid(bd),.done_ready(ack),.done_error(berr),.error_code(bc));
integral_image #(.WIDTH(W),.HEIGHT(H),.BITS(12)) integral(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(idr),.abort(1'b0),
.s_data(braw),.s_valid(bv),.s_ready(ir),.s_sof(bs),.s_eol(be),.s_last(bl),
.done_valid(idone),.done_ready(ack),.done_error(ierr),.error_code(ic),.frame_valid(fvalid),.accepted_pixels(accepted),
.query_valid(qv),.query_ready(qr),.query_x0(x0),.query_y0(y0),.query_x1(x1),.query_y1(y1),
.result_valid(rv),.result_ready(rr),.result_sum(rsum),.result_sqsum(rsq),.result_count(rcount),.result_error(rerr),.result_error_code(rc));
reg[11:0]pixels[0:F*N-1],bexp[0:F*N-1];reg[15:0]rects[0:F*Q*4-1];
reg[31:0]sums[0:F*Q-1],counts[0:F*Q-1];reg[39:0]squares[0:F*Q-1];reg[3:0]errors[0:F*Q-1];
integer i,j,f,nb=0,nq=0,cycle=0;reg take,hb=0,hr=0;reg[14:0]bt;reg[108:0]rt;reg[31:0]rng=9187;
always @(posedge clk)begin
cycle=cycle+1;if(cycle>2000000)$fatal(1,"timeout");
if(rst_n)begin
if(hb&&(!bv||{braw,bs,be,bl}!==bt))$fatal(1,"RAW hold");hb=bv&&!(ce&&ir);bt={braw,bs,be,bl};
if(hr&&(!rv||{rsum,rsq,rcount,rerr,rc}!==rt))$fatal(1,"query hold");hr=rv&&!(ce&&rr);rt={rsum,rsq,rcount,rerr,rc};
if(ce&&bv&&ir)begin
if(braw!==bexp[nb]||bs!==(nb%N==0)||be!==(nb%W==W-1)||bl!==(nb%N==N-1))$fatal(1,"RAW %d",nb);nb=nb+1;end
if(ce&&rv&&rr)begin
if(nq>=F*Q||rsum!==sums[nq]||rsq!==squares[nq]||rcount!==counts[nq]||rc!==errors[nq]||rerr!==(errors[nq]!=0))$fatal(1,"query %d sum%d/%d sq%d/%d count%d/%d error%d/%d",nq,rsum,sums[nq],rsq,squares[nq],rcount,counts[nq],rc,errors[nq]);nq=nq+1;end
end end
task tick;begin @(negedge clk);#1;rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[3];rr=rng[2]|rng[5];end endtask
initial begin
$readmemh("pixels.mem",pixels);$readmemh("bexp.mem",bexp);$readmemh("rects.mem",rects);$readmemh("sums.mem",sums);$readmemh("squares.mem",squares);$readmemh("counts.mem",counts);$readmemh("errors.mem",errors);
repeat(3)@(negedge clk);#1;rst_n=1;
for(f=0;f<F;f=f+1)begin
ce=1;pattern=f;#1;if(!br||!idr)$fatal(1,"start ready");start=1;@(negedge clk);#1;start=0;
i=0;while(i<N)begin sv=1;raw=pixels[f*N+i];sof=i==0;eol=i%W==W-1;last=i==N-1;@(posedge clk);take=ce&&sr;if(take)i=i+1;tick;end sv=0;
while(!bd||!idone)tick;
if(berr||ierr||bc||ic||nb!=(f+1)*N||accepted!=N||!fvalid)$fatal(1,"frame completion");
ce=0;ack=1;repeat(3)@(negedge clk);#1;if(!bd||!idone)$fatal(1,"done hold");ce=1;@(negedge clk);#1;ack=0;
for(j=0;j<Q;j=j+1)begin
x0=rects[(f*Q+j)*4];y0=rects[(f*Q+j)*4+1];x1=rects[(f*Q+j)*4+2];y1=rects[(f*Q+j)*4+3];qv=1;take=0;
while(!take)begin @(posedge clk);take=ce&&qr;tick;end qv=0;
while(nq<f*Q+j+1)tick;
if(!fvalid)$fatal(1,"query invalidated frame");
end
// Last result handshake can advance READY on the same edge; next start occurs after tick.
end
$display("PASS RAW_INTEGRAL frames=%d RAWpixels=%d queries=%d",F,nb,nq);$finish;
end endmodule'''

def main():
    folder=evidence_dir('raw_integral');rng=random.Random(3951)
    arrays={k:[] for k in ('pixels','bexp','rects','sums','squares','counts','errors')}
    for f in range(4):
        black=[37+f,49+f,71+f,89+f]
        raw=[]
        for y in range(7):
            for x in range(9):
                plane=(((y&1)^((f>>1)&1))<<1)|((x&1)^(f&1))
                raw.append(black[plane] if y<2 else rng.randrange(4096))
        corrected=[]
        for y in range(7):
            for x in range(9):
                plane=(((y&1)^((f>>1)&1))<<1)|((x&1)^(f&1))
                corrected.append(max(0,min(4095,raw[y*9+x]-black[plane]+11)))
        rects=[(x,y,x+1,y+1) for y in range(7) for x in range(9)]
        rects.extend([(0,0,9,7),(3,2,3,6),(1,7,9,7)])
        for _ in range(16):
            x0,x1=sorted([rng.randrange(10),rng.randrange(10)]);y0,y1=sorted([rng.randrange(8),rng.randrange(8)])
            rects.append((x0,y0,x1,y1))
        rects.extend([(0,0,10,7),(4,2,3,6),(0,4,9,2)])
        assert len(rects)==85
        arrays['pixels'].extend(raw);arrays['bexp'].extend(corrected)
        for x0,y0,x1,y1 in rects:
            arrays['rects'].extend((x0,y0,x1,y1))
            error=x0>x1 or y0>y1 or x1>9 or y1>7
            values=[] if error else [corrected[y*9+x] for y in range(y0,y1) for x in range(x0,x1)]
            arrays['errors'].append(int(error));arrays['sums'].append(sum(values));arrays['squares'].append(sum(v*v for v in values));arrays['counts'].append(len(values))
    sources=[PACKAGE/'image/raw_black_level/raw_black_level.sv',PACKAGE/'image/integral_image/integral_image.sv']
    with tempfile.TemporaryDirectory(prefix='raw_integral_') as tmp:
        path=Path(tmp)
        for name,values in arrays.items():(path/(name+'.mem')).write_text('\n'.join(f'{int(v):x}' for v in values))
        (path/'tb.sv').write_text(TB)
        execute(['iverilog','-g2012','-s','tb','-o',path/'sim',*sources,path/'tb.sv'],ROOT,folder/'compile.log')
        execute(['vvp',path/'sim'],path,folder/'simulation.log',timeout=180)
    write_json(folder/'results.json',dict(status='PASS',frames=4,pixels=252,rectangle_queries=340,invalid_queries=12,board_tested=False,
        sources={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}))
    print(folder,flush=True)

if __name__=='__main__':main()
