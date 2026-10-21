"""Actual same-frame optical-black -> gray-world RAW -> MHC RTL chain."""
import hashlib
import tempfile
from pathlib import Path
import numpy as np
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json
from test_lens_malvar import malvar_oracle

TB = r'''module tb;
localparam W=9,H=7,N=W*H,F=8;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,sv=0,sof=0,eol=0,last=0,ack=0,mr=0;
reg [11:0] raw;reg[1:0] pattern;
wire br,sr,bv,ar,bs,be,bl,bd,berr,adr,av,dr,as_,ae,al,ad,aerr,dd,derr,mv,ms,me,ml;
wire [11:0] braw,araw;wire[35:0]rgb;wire[7:0]bc,dc;wire[3:0]ac;
wire[47:0] levels;wire[63:0]gains;wire sat,ddr;
raw_black_level #(.WIDTH(W),.HEIGHT(H),.BITS(12)) black(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(br),
.cfg_auto(1'b1),.cfg_pattern(pattern),.cfg_black_levels(48'b0),.cfg_target_pedestal(12'b0),
.cfg_roi_x(16'd0),.cfg_roi_y(16'd0),.cfg_roi_width(16'd9),.cfg_roi_height(16'd2),.abort(1'b0),
.s_data(raw),.s_valid(sv),.s_ready(sr),.s_sof(sof),.s_eol(eol),.s_last(last),
.m_data(braw),.m_valid(bv),.m_ready(ar),.m_sof(bs),.m_eol(be),.m_last(bl),
.done_valid(bd),.done_ready(ack),.done_error(berr),.error_code(bc),.applied_black_levels(levels));
raw_white_balance #(.WIDTH(W),.HEIGHT(H),.BITS(12)) awb(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(adr),
.cfg_auto(1'b1),.cfg_pattern(pattern),.cfg_roi_x0(16'd0),.cfg_roi_y0(16'd2),.cfg_roi_x1(16'd8),.cfg_roi_y1(16'd6),
.cfg_low(12'd1),.cfg_high(12'd4095),.cfg_gain_min(16'd1024),.cfg_gain_max(16'd16384),.cfg_manual_gains(64'b0),
.s_data(braw),.s_valid(bv),.s_ready(ar),.s_sof(bs),.s_eol(be),.s_last(bl),
.m_data(araw),.m_saturated(sat),.m_valid(av),.m_ready(dr),.m_sof(as_),.m_eol(ae),.m_last(al),
.done_valid(ad),.done_ready(ack),.done_error(aerr),.error_code(ac),.applied_gains(gains));
malvar_demosaic #(.WIDTH(W),.HEIGHT(H),.BITS(12)) mhc(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(ddr),.cfg_pattern(pattern),.abort(1'b0),
.s_data(araw),.s_valid(av),.s_ready(dr),.s_sof(as_),.s_eol(ae),.s_last(al),
.m_data(rgb),.m_valid(mv),.m_ready(mr),.m_sof(ms),.m_eol(me),.m_last(ml),
.done_valid(dd),.done_ready(ack),.done_error(derr),.error_code(dc));
reg[11:0]pixels[0:F*N-1],bexp[0:F*N-1];reg[12:0]aexp[0:F*N-1];reg[35:0]expected[0:F*N-1];
reg[47:0]lexp[0:F-1];reg[63:0]gexp[0:F-1];
integer i,f,nb=0,na=0,nm=0,cycle=0;reg take,hb=0,ha=0,hm=0;reg[14:0]bt;reg[15:0]at;reg[38:0]mt;reg[31:0]rng=739;
always @(posedge clk)begin
cycle=cycle+1;if(cycle>2000000)$fatal(1,"timeout");
if(rst_n)begin
if(hb&&(!bv||{braw,bs,be,bl}!==bt))$fatal(1,"black hold");hb=bv&&!(ce&&ar);bt={braw,bs,be,bl};
if(ha&&(!av||{araw,sat,as_,ae,al}!==at))$fatal(1,"AWB hold");ha=av&&!(ce&&dr);at={araw,sat,as_,ae,al};
if(hm&&(!mv||{rgb,ms,me,ml}!==mt))$fatal(1,"RGB hold");hm=mv&&!(ce&&mr);mt={rgb,ms,me,ml};
if(ce&&bv&&ar)begin
if(braw!==bexp[nb]||bs!==(nb%N==0)||be!==(nb%W==W-1)||bl!==(nb%N==N-1))$fatal(1,"black pixel %d",nb);nb=nb+1;end
if(ce&&av&&dr)begin
if({sat,araw}!==aexp[na]||as_!==(na%N==0)||ae!==(na%W==W-1)||al!==(na%N==N-1))$fatal(1,"AWB pixel %d",na);na=na+1;end
if(ce&&mv&&mr)begin
if(rgb!==expected[nm]||ms!==(nm%N==0)||me!==(nm%W==W-1)||ml!==(nm%N==N-1))$fatal(1,"RGB pixel %d",nm);nm=nm+1;end
end end
task tick;begin @(negedge clk);#1;rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[3];mr=rng[2]|rng[5];end endtask
initial begin
$readmemh("pixels.mem",pixels);$readmemh("bexp.mem",bexp);$readmemh("aexp.mem",aexp);$readmemh("expected.mem",expected);$readmemh("lexp.mem",lexp);$readmemh("gexp.mem",gexp);
repeat(3)@(negedge clk);#1;rst_n=1;
for(f=0;f<F;f=f+1)begin
ce=1;pattern=f%4;#1;if(!br||!adr||!ddr)$fatal(1,"start ready");start=1;@(negedge clk);#1;start=0;
i=0;while(i<N)begin sv=1;raw=pixels[f*N+i];sof=i==0;eol=i%W==W-1;last=i==N-1;@(posedge clk);take=ce&&sr;if(take)i=i+1;tick;end sv=0;
while(!bd||!ad||!dd)tick;
if(berr||aerr||derr||bc||ac||dc||nb!=(f+1)*N||na!=(f+1)*N||nm!=(f+1)*N||levels!==lexp[f]||gains!==gexp[f])$fatal(1,"completion/stats frame %d",f);
ce=0;ack=1;repeat(3)@(negedge clk);#1;if(!bd||!ad||!dd)$fatal(1,"done hold");ce=1;@(negedge clk);#1;ack=0;
end
$display("PASS RAW_CALIBRATION frames=%d RGBpixels=%d",F,nm);$finish;
end endmodule'''

def main():
    folder=evidence_dir('raw_calibration')
    arrays={key:[] for key in ('pixels','bexp','aexp','expected','lexp','gexp')}
    rng=np.random.default_rng(19397)
    for f in range(8):
        pattern=f%4
        phase=np.fromfunction(lambda y,x: ((y.astype(int)&1)^((pattern>>1)&1))*2+((x.astype(int)&1)^(pattern&1)),(7,9),dtype=int)
        black=np.array([31,43,59,71])+f*3
        signal=rng.integers(40,3200,(7,9));signal[:2]=0
        raw=np.minimum(4095,signal+black[phase])
        means=[]
        for p in range(4):
            vals=raw[:2][phase[:2]==p];means.append((int(vals.sum())+len(vals)//2)//len(vals))
        corrected=np.clip(raw-np.array(means)[phase],0,4095)
        sums=[];counts=[]
        for p in range(4):
            vals=corrected[2:][(phase[2:]==p)&(corrected[2:]>=1)]
            sums.append(int(vals.sum()));counts.append(len(vals))
        gs=sums[1]+sums[2];gc=counts[1]+counts[2]
        gains=[]
        for s,c in zip(sums,counts):
            numerator=gs*c*4096;denominator=gc*s
            gains.append(max(1024,min(16384,(numerator+denominator//2)//denominator)))
        product=(corrected*np.array(gains)[phase]+2048)//4096
        balanced=np.minimum(4095,product)
        arrays['pixels'].extend(raw.ravel());arrays['bexp'].extend(corrected.ravel())
        arrays['aexp'].extend(((product>4095).astype(int)*4096+balanced).ravel())
        arrays['expected'].extend(malvar_oracle(balanced,pattern))
        arrays['lexp'].append(sum(v<<(12*p) for p,v in enumerate(means)))
        arrays['gexp'].append(sum(v<<(16*p) for p,v in enumerate(gains)))
    sources=[PACKAGE/'image/raw_black_level/raw_black_level.sv',PACKAGE/'image/raw_white_balance/raw_white_balance.sv',PACKAGE/'image/malvar_demosaic/malvar_demosaic.sv']
    with tempfile.TemporaryDirectory(prefix='raw_calibration_') as tmp:
        path=Path(tmp)
        for name,values in arrays.items():(path/(name+'.mem')).write_text('\n'.join(f'{int(v):x}' for v in values))
        (path/'tb.sv').write_text(TB)
        execute(['iverilog','-g2012','-s','tb','-o',path/'sim',*sources,path/'tb.sv'],ROOT,folder/'compile.log')
        execute(['vvp',path/'sim'],path,folder/'simulation.log',timeout=180)
    write_json(folder/'results.json',dict(status='PASS',frames=8,pixels=504,board_tested=False,
        sources={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}))
    print(folder,flush=True)

if __name__=='__main__':main()
