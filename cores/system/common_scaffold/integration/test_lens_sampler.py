"""Real Brown-Conrady map -> production bilinear frame sampler, exact pixels."""
from pathlib import Path
import hashlib, random, tempfile, sys
sys.dont_write_bytecode=True
from tooling import PACKAGE, evidence_dir, execute, write_json
SOURCES=[PACKAGE/'image/lens_distortion/lens_distortion_map.sv',PACKAGE/'image/geometry/rtl/img_geo_frame_sampler.v']

def coordinate(x,y,c):
    fx,fy,cx,cy,ix,iy,k1,k2,k3,p1,p2=c
    ov=False
    def sat(n):
        nonlocal ov
        ov |= not -2147483648<=n<=2147483647
        return min(2147483647,max(-2147483648,n))
    def a(x,y):return sat(x+y)
    def m(x,y,s=16):
        z=x*y
        return sat((-1 if z<0 else 1)*((abs(z)+(1<<(s-1)))>>s))
    x=m(a(x<<16,-cx),ix,30);y=m(a(y<<16,-cy),iy,30)
    xx=m(x,x);yy=m(y,y);xy=m(x,y);rr=a(xx,yy)
    radial=a(m(a(m(a(m(k3,rr),k2),rr),k1),rr),65536)
    tx=m(p1,xy);ty=m(p2,xy)
    xd=a(a(m(x,radial),a(tx,tx)),m(p2,a(rr,a(xx,xx))))
    yd=a(a(m(y,radial),a(ty,ty)),m(p1,a(rr,a(yy,yy))))
    return a(m(fx,xd),cx),a(m(fy,yd),cy),ov

def pixel(x,y):return (x*37+y*61+x*y*13+19)%256

def main():
    folder=evidence_dir('lens_sampler')
    rng=random.Random(92018)
    cases=[[8<<16,8<<16,3<<16,2<<16,1<<27,1<<27,0,0,0,0,0]]
    for _ in range(24):cases.append([8<<16,8<<16,3<<16,2<<16,1<<27,1<<27,*[rng.randint(-90000,90000) for _ in range(5)]])
    cases += [[65536,65536,0,0,1<<30,1<<30,*([2147483647]*5)]]
    expected=[];requests=[];border=overflow=nonzero_fraction=0
    for c in cases:
        for y in range(5):
            for x in range(7):
                sx,sy,ov=coordinate(x,y,c)
                outside=sx<0 or sy<0 or sx>6*65536 or sy>4*65536
                if outside or ov:
                    result=173;border+=1;overflow+=int(ov)
                else:
                    # Adapter takes Q16[31:8] only after signed validity classification.
                    qx=sx>>8;qy=sy>>8;x0=qx>>8;y0=qy>>8
                    x1=min(6,x0+1);y1=min(4,y0+1);ax=qx&255;ay=qy&255
                    nonzero_fraction+=int(bool(ax or ay))
                    points=[(x0,y0),(x1,y0),(x0,y1),(x1,y1)]
                    requests += [23+yy*11+xx for xx,yy in points]
                    result=(pixel(x0,y0)*(256-ax)*(256-ay)+pixel(x1,y0)*ax*(256-ay)+pixel(x0,y1)*(256-ax)*ay+pixel(x1,y1)*ax*ay+32768)>>16
                expected.append(result|(int(x==0 and y==0)<<8)|(int(x==6)<<9)|(int(x==6 and y==4)<<10))
    with tempfile.TemporaryDirectory(prefix='lens_sampler_') as temporary:
        td=Path(temporary)
        (td/'expected.hex').write_text(''.join(f'{n:x}\n' for n in expected))
        (td/'requests.hex').write_text(''.join(f'{n:x}\n' for n in requests))
        body=''
        for c in cases:
            body+=''.join(f"{name}=32'h{value&0xffffffff:08x};" for name,value in zip('fx fy cx cy ix iy k1 k2 k3 p1 p2'.split(),c))
            body+='while(!cr)tick;cv=1;tick;cv=0;if(!cd||cerr)$fatal(1,"config");while(!sr)tick;sv=1;tick;sv=0;while(!dv)tick;while(output_count<(frame+1)*35)tick;while(!ce)tick;dr=1;tick;dr=0;frame=frame+1;\n'
        tb=TB.replace('@BODY@',body).replace('@PIXELS@',str(len(expected))).replace('@REQUESTS@',str(len(requests)))
        (td/'tb.sv').write_text(tb)
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,folder/'compile.log')
        output=execute(['vvp',td/'sim'],td,folder/'simulation.log',timeout=180)
        assert 'LENS_SAMPLER PASS' in output,output
    result=dict(status='PASS',frames=len(cases),pixels=len(expected),memory_reads=len(requests),border_pixels=border,overflow_pixels=overflow,fractional_pixels=nonzero_fraction,sources_sha256={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES},scope='Actual RTL map to LANES=1 bilinear production sampler; Q16 to Q8 truncation, border on OOB or overflow; randomized CE, requests, delayed responses and output backpressure. Simulation only, no board or timing signoff.')
    write_json(folder/'results.json',result)
    print(output.strip());print(folder)

TB=r"""
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,sv=0,dr=0;
reg signed [31:0] fx,fy,cx,cy,ix,iy,k1,k2,k3,p1,p2;
wire cr,sr,cd,cerr,dv,busy,map_valid,map_ready,oob,ov,sof,eol,eof;
wire [3:0] ec;wire signed [31:0] sx,sy;wire [15:0] mx,my;
lens_distortion_map #(.WIDTH(7),.HEIGHT(5)) mapper(.clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(cv),.cfg_ready(cr),.cfg_fx(fx),.cfg_fy(fy),.cfg_cx(cx),.cfg_cy(cy),.cfg_invfx(ix),.cfg_invfy(iy),.cfg_k1(k1),.cfg_k2(k2),.cfg_k3(k3),.cfg_p1(p1),.cfg_p2(p2),.cfg_done(cd),.cfg_error(cerr),.error_code(ec),.start_valid(sv),.start_ready(sr),.m_src_x(sx),.m_src_y(sy),.m_x(mx),.m_y(my),.m_oob(oob),.m_overflow(ov),.m_valid(map_valid),.m_ready(map_ready),.m_sof(sof),.m_eol(eol),.m_last(eof),.done_valid(dv),.done_ready(dr),.busy(busy));
wire req,rspready,read,valid,ss,se,sl;wire [31:0] addr;wire [7:0] data;wire [3:0] error;
reg reqready=0,rspvalid=0,ready=0;reg [7:0] rspdata=0;
img_geo_frame_sampler #(.LANES(1),.BORDER_DATA(8'd173)) sampler(.clk(clk),.rst_n(rst_n),.clk_en(ce),.s_valid(map_valid),.s_ready(map_ready),.s_x_q8(sx[31:8]),.s_y_q8(sy[31:8]),.s_border(oob||ov),.s_error(4'd0),.s_sof(sof),.s_eol(eol),.s_eof(eof),.s_filter(2'd1),.s_src_width(16'd7),.s_src_height(16'd5),.s_stride(32'd11),.s_base_addr(32'd23),.mem_req_valid(req),.mem_req_ready(reqready),.mem_req_read(read),.mem_req_addr(addr),.mem_rsp_valid(rspvalid),.mem_rsp_ready(rspready),.mem_rsp_data(rspdata),.mem_rsp_error(1'b0),.m_valid(valid),.m_ready(ready),.m_data(data),.m_error(error),.m_sof(ss),.m_eol(se),.m_eof(sl));
reg [10:0] expected[0:@PIXELS@-1];reg [31:0] requests[0:@REQUESTS@-1];
integer output_count=0,request_count=0,frame=0,delay_count=0;reg pending=0;
reg [31:0] lfsr=32'haf124789;
reg [14:0] held;reg held_valid=0;integer ax,ay;
always @(negedge clk)if(rst_n)begin
 lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
 ce=lfsr[2:0]!=0;reqready=lfsr[5:4]!=0;ready=lfsr[8:6]==0;
end
always @(posedge clk)if(rst_n)begin
 if(held_valid&&({data,error,ss,se,sl}!==held||!valid))$fatal(1,"output stability");
 held_valid=valid&&(!ce||!ready);held={data,error,ss,se,sl};
 if(ce)begin
  if(valid&&ready)begin
   if(output_count>=@PIXELS@||error!=0||{sl,se,ss,data}!==expected[output_count])begin $display("index %d actual %h expected %h error %h",output_count,{sl,se,ss,data},expected[output_count],error);$fatal(1,"pixel oracle");end
   output_count=output_count+1;
  end
  if(req&&reqready)begin
   if(pending||rspvalid||request_count>=@REQUESTS@||addr!==requests[request_count]||!read)$fatal(1,"memory request oracle");
   request_count=request_count+1;pending<=1;delay_count<=1+lfsr[12:9];
   ay=(addr-23)/11;ax=(addr-23)%11;
   if(ax>6||ay>4)$fatal(1,"invalid source memory address");
   rspdata<=(ax*37+ay*61+ax*ay*13+19)%256;
  end
  if(pending)begin
   if(delay_count==0)begin pending<=0;rspvalid<=1;end else delay_count<=delay_count-1;
  end
  if(rspvalid&&rspready)rspvalid<=0;
 end
end
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
initial begin #20000000;$fatal(1,"timeout");end
initial begin
 $readmemh("expected.hex",expected);$readmemh("requests.hex",requests);
 @(negedge clk);tick;rst_n=1;tick;
 @BODY@
 repeat(20)tick;
 if(output_count!=@PIXELS@||request_count!=@REQUESTS@||pending||rspvalid)$fatal(1,"final counts");
 $display("LENS_SAMPLER PASS pixels=%0d requests=%0d",output_count,request_count);$finish;
end
endmodule
"""
if __name__=='__main__':main()
