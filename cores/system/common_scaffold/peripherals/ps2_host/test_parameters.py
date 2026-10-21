from run_tests import *
def main():
 rows=[]
 for key,val in [('CLK_HZ',999999),('CLK_HZ',250000001),('FILTER_CYCLES',0),('FILTER_CYCLES',33),('RX_FIFO_DEPTH',1),('RX_FIFO_DEPTH',257),('INHIBIT_CYCLES',3),('INHIBIT_CYCLES',25000001),('REQUEST_CYCLES',1),('REQUEST_CYCLES',2500001),('EDGE_TIMEOUT_CYCLES',15),('EDGE_TIMEOUT_CYCLES',25000001),('IDLE_CYCLES',1),('IDLE_CYCLES',2500001)]:
  tb=f'''module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0;wire tx_ready,tx_done_valid,rx_error_valid,ps2_clk_drive_low,ps2_data_drive_low;wire[7:0]tx_error_code,rx_error_code;
 ps2_host #(.{key}({val}))dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.abort(1'b0),.ps2_clk_in(1'b1),.ps2_data_in(1'b1),.tx_data(8'hff),.tx_valid(1'b1),.tx_done_ready(1'b0),.rx_ready(1'b0),.rx_error_ready(1'b0),.tx_ready(tx_ready),.tx_done_valid(tx_done_valid),.tx_error_code(tx_error_code),.rx_error_valid(rx_error_valid),.rx_error_code(rx_error_code),.ps2_clk_drive_low(ps2_clk_drive_low),.ps2_data_drive_low(ps2_data_drive_low));
 initial begin #12;rst_n=1;#50;if(!tx_done_valid||tx_error_code!=1||!rx_error_valid||rx_error_code!=1||ps2_clk_drive_low||ps2_data_drive_low)$fatal(1,"invalid params");$display("PASS INVALID");$finish;end endmodule'''
  execute_tb(f'invalid_{key}_{val}',tb);rows.append(dict(parameter=key,value=val,status='PASS'))
 (H/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=rows),indent=2)+'\n');print(json.dumps(rows))
if __name__=='__main__':main()
