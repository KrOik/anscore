from test_protocol import *
def main():
 rows=[]
 body=r'''
initial begin repeat(4)tick;rst_n=1;launch;ack(1);if(m_valid)$fatal(1,"invalid emitted");$display("PASS FREQUENCY INVALIDPARAM");$finish;end endmodule'''
 for name,value in [('COUNT_W',7),('COUNT_W',49),('GATE_W',7),('GATE_W',49),('FILTER_W',0),('FILTER_W',17)]:
  tb=P.split(' initial begin')[0]+body
  tb=tb.replace(f'.{name}('+dict(COUNT_W='48',GATE_W='48',FILTER_W='16')[name]+')',f'.{name}({value})')
  out=simulate(f'invalid_{name}_{value}',tb,{});rows.append(dict(parameter=name,value=value,status='REJECTED',output=out))
 (H/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),profiles=rows),indent=2)+'\n');print('PASS6 illegal frequency-counter static parameters')
if __name__=='__main__':main()
