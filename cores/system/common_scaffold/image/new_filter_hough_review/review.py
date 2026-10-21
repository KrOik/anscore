"""Read-only frozen-source review with tiny direct combinational Hough checks."""
from pathlib import Path
import sys,json,hashlib,tempfile,datetime,re
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent;IMAGE=HERE.parent
sys.path.insert(0,str(IMAGE.parent));from integration.tooling import execute
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
checks=[];before={}
for name in ['hough_lines_full','wiener_denoise']:
    p=IMAGE/name;freeze=json.loads((p/'freeze_hashes.json').read_text())
    sources=freeze.get('sources',freeze)
    for file,expected in sources.items():
        if file in ['error_evidence.json','evidence.json','synthesis.json','synthesis.log']:continue
        actual=sha(p/file);assert actual==expected,(name,file,actual,expected)
        checks.append(dict(file=f'{name}/{file}',sha256=actual,match=True));before[f'{name}/{file}']=actual
    rtl='hough_lines_full.sv' if name=='hough_lines_full' else 'wiener_denoise.sv'
    for file in (['test_result.json','protocol_result.json','synthesis_result.json'] if name=='hough_lines_full' else ['evidence.json','error_evidence.json','synthesis.json']):
        data=json.loads((p/file).read_text());bound=data.get('rtl_sha256',data.get('sources',{}).get(rtl))
        assert bound==sha(p/rtl),(name,file)
        checks.append(dict(file=f'{name}/{file}',rtl_sha256=bound,match=True))
tb='''module tb;
 hough_lines_full #(.WIDTH(32),.HEIGHT(32),.THETA_STEP(1),.TRIG_FILE("ROM")) dut(.clk(1'b0),.rst_n(1'b1),.ce(1'b0));
 integer a,b,r,s,i,j,angle_expected,rhod,wrapped,count=0;
 integer angles[0:6];integer rhos[0:4];
 initial begin angles[0]=0;angles[1]=1;angles[2]=89;angles[3]=90;angles[4]=91;angles[5]=178;angles[6]=179;
 rhos[0]=-45;rhos[1]=-31;rhos[2]=0;rhos[3]=31;rhos[4]=45;
 for(a=0;a<7;a=a+1)for(b=0;b<7;b=b+1)for(r=0;r<5;r=r+1)for(s=0;s<5;s=s+1)begin
 dut.scan_theta=angles[a];dut.m_theta=angles[b];dut.scan_rho=rhos[r];dut.m_rho=rhos[s];dut.theta_nms=90;dut.rho_nms=0;
 angle_expected=angles[a]-angles[b];if(angle_expected<0)angle_expected=-angle_expected;wrapped=angle_expected>90;if(wrapped)angle_expected=180-angle_expected;
 rhod=wrapped?rhos[r]+rhos[s]:rhos[r]-rhos[s];if(rhod<0)rhod=-rhod;
 #1;if(dut.angle_distance!==angle_expected||dut.rho_distance!==rhod||dut.suppress!==(angle_expected<=90&&rhod==0))$fatal(1,"NMS signed/wrap mismatch");count=count+1;
 end
 for(i=0;i<180;i=i+1)for(j=-45;j<=45;j=j+1)begin
 dut.theta=i;dut.rho=j;#1;
 if(dut.theta_base!==i*91||dut.rho_offset!==(j+45)||dut.theta_base+dut.rho_offset!=(i*91+j+45))$fatal(1,"bin address width");
 end
 if(dut.theta_base+dut.rho_offset!=16379)$fatal(1,"terminal bin address");
 $display("TARGET PASS NMS=%0d addresses=16380",count);$finish;end endmodule'''
rtl=IMAGE/'hough_lines_full'/'hough_lines_full.sv';rom=IMAGE/'hough_lines_full'/'trig.mem'
with tempfile.TemporaryDirectory(prefix='new_filter_hough_review_') as temporary:
    td=Path(temporary);(td/'tb.sv').write_text(tb.replace('ROM',rom.as_posix()),encoding='utf-8')
    execute(['iverilog','-g2012','-s','tb','-o',td/'sim',rtl,td/'tb.sv'],HERE,td/'compile.log')
    output=execute(['vvp',td/'sim'],HERE,td/'run.log');assert 'TARGET PASS' in output;print(output.strip())
assert before=={f:sha(IMAGE/f) for f in before}
# Analytic worst-case ranges; conservative even where branch constraints
# would give tighter convex-combination bounds.
n=25;S=n*255;Q=n*255**2;Vmax=(n*n*255**2)//4;T=65535*n*n
widths=dict(sum_max=S,sumsq_max=Q,central_moment_max=Vmax,scaled_noise_max=T,denominator_max=n*Vmax,first_product_max=S*T,second_product_max=Vmax*n*255,conservative_numerator_max=S*T+Vmax*n*255+(n*Vmax)//2)
assert S<2**13 and Q<2**21 and Vmax<2**32 and T<2**32 and widths['denominator_max']<2**32 and widths['conservative_numerator_max']<2**48
report=dict(status='PASS',utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),freeze_checks=checks,hough_directed_combination_cases=1225,hough_all_bin_addresses=16380,hough_output=output.strip(),wiener_analytic_width_bounds=widths,source_assets_unchanged=True,large_regression_rerun=False,board_access=False)
(HERE/'review_evidence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
print('ALL PASS; frozen source/assets unchanged')
