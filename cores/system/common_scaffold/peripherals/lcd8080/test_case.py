from test_lcd8080 import *
BODY=r'''
integer i,j;
initial begin
 repeat(3)@(negedge clk);#1;rst_n=1;

 write_job(0,1,'h11);write_job(1,2,'h51);
 expect_beat(1,1,'hd3);launch(1,1,1);get_word('hd3,1);finish_job(0);
 @(negedge clk);#1;if(observed!=4||exp_count!=4)$fatal(1,"CASE beat count");
 $display("PASS LCD8080 CASE jobs=3 writes=3 reads=1 beats=4");$finish;

end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
'''
if __name__=='__main__':
 frozen=hashes();tb=TB.split('integer i,j;')[0]+BODY
 row=run_tb('case',tb.replace('@WIDTH@','8'));assert hashes()==frozen
 (HERE/'case_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,case=row),indent=2)+'\n')
