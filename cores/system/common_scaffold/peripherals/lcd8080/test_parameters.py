from test_lcd8080 import *
BODY=r'''
integer i,j;
initial begin
 repeat(3)@(negedge clk);#1;rst_n=1;

 @BODY@
 $display("PASS LCD8080 PARAMETERS @LABEL@");$finish;

end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
'''
if __name__=='__main__':
 frozen=hashes();rows=[]
 for width,cw,legal in [(7,16,False),(32,16,False),(8,0,False),(16,25,False),(8,1,True),(16,24,True)]:
  code="write_job(1,1,'h64);" if legal else 'launch(0,1,1);finish_job(1);if(observed!=0)$fatal(1,"invalid static cfg emitted bus cycle");'
  label=f'w{width}c{cw}'
  tb=(TB.split('integer i,j;')[0]+BODY.replace('@BODY@',code).replace('@LABEL@',label)).replace('@WIDTH@',str(width)).replace('#(.BUS_WIDTH(W))','#(.BUS_WIDTH(W),.COUNT_W('+str(cw)+'))')
  rows.append(run_tb(label,tb))
 assert hashes()==frozen
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
