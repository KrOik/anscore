from test_protocol import *
BODY=r'''
initial begin
 repeat(3)@(negedge clk);#1;rst_n=1;start_valid=1;
 @(posedge clk);#1;@(negedge clk);#1;start_valid=0;
 if(!done_valid||error_code!=1||busy||m_valid)$fatal(1,"illegal static parameters");
 $display("PASS PULSE invalid parameter profile");$finish;
end
initial begin #10000;$fatal(1,"watchdog");end
endmodule
'''
if __name__=='__main__':
 frozen=hashes();rows=[run_protocol(f'invalid_w{w}f{f}',BODY,w,f) for w,f in [(15,8),(49,8),(32,0),(32,17)]]
 assert hashes()==frozen
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
