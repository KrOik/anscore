from run_tests import *
P=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,input_pin=0,start_valid=0,abort=0,m_ready=0,done_ready=0;
reg[47:0]cfg_gate_clocks=2;reg[15:0]cfg_filter=1;reg[1:0]cfg_edge_mode=0;
reg cfg_range_enable=0;reg[47:0]cfg_min_edges=0,cfg_max_edges=48'hffffffffffff;
wire start_ready,busy,done_valid,m_valid,drop_sticky;wire[47:0]m_edges,m_gate_clocks;wire[31:0]m_window_index,drop_count;wire[2:0]m_flags;wire[7:0]error_code;
frequency_counter #(.COUNT_W(48),.GATE_W(48),.FILTER_W(16))dut(.*);
integer ticks=0,got=0,checks=0;reg[130:0]helddata;reg held=0;
always @(posedge clk)begin
 ticks=ticks+1;if(ticks>10000)$fatal(1,"watchdog");
 if(rst_n)begin
 if(held&&(!m_valid||{m_flags,m_window_index,m_edges,m_gate_clocks}!==helddata))$fatal(1,"held token changed");
 held=m_valid&&!(ce&&m_ready);helddata={m_flags,m_window_index,m_edges,m_gate_clocks};
 if(ce&&m_valid&&m_ready)begin if(m_edges||m_flags!=1||m_gate_clocks!=2||m_window_index!=got)$fatal(1,"drain tuple");got=got+1;end
 end else held=0;
end
 task tick;begin @(negedge clk);#1;end endtask
 task launch;begin while(!start_ready)tick;ce=1;start_valid=1;tick;start_valid=0;end endtask
 task ack;input integer code;begin while(!done_valid)tick;if(error_code!=code||busy)$fatal(1,"terminal");ce=0;done_ready=1;repeat(4)tick;if(!done_valid)$fatal(1,"CE0DONEack");ce=1;tick;done_ready=0;if(!start_ready)$fatal(1,"restart");checks=checks+1;end endtask
 initial begin repeat(4)tick;rst_n=1;
 cfg_gate_clocks=0;launch;ack(1);cfg_gate_clocks=2;
 cfg_edge_mode=3;launch;ack(1);cfg_edge_mode=0;
 cfg_range_enable=1;cfg_min_edges=3;cfg_max_edges=2;launch;ack(1);cfg_range_enable=0;cfg_min_edges=0;cfg_max_edges=48'hffffffffffff;
 // Entirely captured descriptor; live invalid inputs must not alter the active gates.
 launch;cfg_gate_clocks=0;cfg_edge_mode=3;cfg_filter=65535;
 while(!m_valid)tick;ce=0;abort=1;repeat(12)tick;if(done_valid||!busy||!drop_sticky||drop_count==0)$fatal(1,"CE0 physical gates/abort");
 ce=1;tick;abort=0;ce=0;m_ready=1;repeat(8)tick;if(done_valid||!busy||!m_valid)$fatal(1,"abort revoked token");
 ce=1;while(!done_valid)tick;if(got!=2)$fatal(1,"oldest two gates not preserved");ack(3);m_ready=0;
 // Maximum48bit gate accepted and not prematurely wrapped; abort drops partial gate.
 cfg_gate_clocks=48'hffffffffffff;cfg_edge_mode=2;launch;repeat(100)tick;if(!busy||m_valid||drop_count)$fatal(1,"max gate");abort=1;tick;abort=0;ack(3);
 // Reset withCE0 overrides acquisition and a held valid output.
 cfg_gate_clocks=2;cfg_filter=0;launch;while(!m_valid)tick;ce=0;rst_n=0;tick;
 if(m_valid||busy||done_valid||drop_count||!start_ready)$fatal(1,"reset CE0");rst_n=1;ce=1;checks=checks+1;
 $display("PASS FREQUENCY PROTOCOL checks=%0d descriptor/invalid/abort/held/CE0/drop/reset/maxgate48",checks);$finish;end
endmodule'''
def main():
 out=simulate('protocol',P,{});print(out);(H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),scope='Runtime invalid descriptors; captured configuration, CE0 physical windows/drop and ignored abort, irrevocable held gate through abort/drain, oldest queue order, max48bit gate accepted/partial abort, CE0 reset',output=out),indent=2)+'\n')
if __name__=='__main__':main()
