"""Independent HX711 pin timing, signed-data and next-conversion-tag peer test."""
from pathlib import Path
import sys,tempfile,json,hashlib,re
H=Path(__file__).resolve().parent;O=H.parent/'hx711_adc';sys.path.insert(0,str(H.parents[1]/'integration'))
from tooling import execute
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
TB=r"""`timescale 1ns/1ps
module tb;
reg clk=0;always #@HALF@ clk=~clk;
reg rst_n=0,ce=1,abort=0,power_down=0,req_valid=0,dout=1,out_ready=0;reg[1:0]req_mode=0;
wire req_ready,pd_sck,out_valid,busy,powered_down;wire signed[23:0]out_data;wire[1:0]out_mode,out_next_mode;wire[2:0]out_error;wire[31:0]out_sequence,accepted_count,completed_count,dropped_count,timeout_count;
hx711_adc #(.CLOCK_HZ(@CLOCK@),.SCK_HIGH_NS(@HIGH@),.SCK_LOW_NS(@LOW@),.READY_TIMEOUT_US(200),.POWERDOWN_US(80),.WAKE_US(10),.FIFO_DEPTH(2))dut(.*);
integer rises=0,falls=0,words=0,signed_negative=0,seq=0,physical_mode=3,physical_pulses=0,powercycles=0;time last_rise,maximum_normal_high=0;reg rising_again;
always @(posedge pd_sck)begin rises=rises+1;last_rise=$time;end
always @(negedge pd_sck)begin falls=falls+1;if($time-last_rise>60000)begin physical_mode=0;powercycles=powercycles+1;end end
task tick;begin @(negedge clk);#1;end endtask
task ready_idle;begin while(!req_ready)tick;end endtask
task request;input integer mode;begin ready_idle;req_mode=mode;req_valid=1;tick;req_valid=0;end endtask
task pulse_end;input time begun;time width;begin @(negedge pd_sck);width=$time-begun;
 if(width<200||width>=50000)$fatal(1,"normal high width %0t",width);if(width>maximum_normal_high)maximum_normal_high=width;
end endtask
// This device is driven solely by real PD_SCK transitions. DOUT changes at
// datasheet maximum100ns after rising edge; no DUT state or owner model used.
task sensor_word;input[23:0]value;integer bitnum;time begun;begin
 physical_pulses=0;dout=0;
 for(bitnum=23;bitnum>=0;bitnum=bitnum-1)begin @(posedge pd_sck);begun=$time;physical_pulses=physical_pulses+1;#100;dout=value[bitnum];pulse_end(begun);end
 begin : extra
 forever begin
  rising_again=0;
  fork : gap_or_edge
   begin @(posedge pd_sck);rising_again=1;end
   begin #@GAP@;end
  join_any
  disable gap_or_edge;
  if(!rising_again)disable extra;
  begun=$time;physical_pulses=physical_pulses+1;#100;dout=1;pulse_end(begun);
 end end
 if(physical_pulses<25||physical_pulses>27)$fatal(1,"pulse count%0d",physical_pulses);
 physical_mode=physical_pulses-25;words=words+1;
end endtask
task consume;input[23:0]value;input integer cm,nm,err,expected_seq;reg[62:0]held;begin
 while(!out_valid)tick;
 if(out_data!==value||out_mode!==cm||out_next_mode!==nm||out_error!==err||out_sequence!==expected_seq)$fatal(1,"packet val%h cm%0d nm%0d err%0d seq%0d",out_data,out_mode,out_next_mode,out_error,out_sequence);
 if(err==0&&value[23])begin if($signed(out_data)>=0)$fatal(1,"signed negative");signed_negative=signed_negative+1;end
 held={out_sequence,out_error,out_next_mode,out_mode,out_data};ce=0;out_ready=0;
 repeat(13)tick;if(!out_valid||{out_sequence,out_error,out_next_mode,out_mode,out_data}!==held)$fatal(1,"backpressure/CE changed packet");
 // Output transport is standard ready/valid, independent of request CE.
 out_ready=1;tick;out_ready=0;if(out_valid)$fatal(1,"CE0output pop");ce=1;
end endtask
task sample;input[23:0]value;input integer nextmode;integer oldmode;begin
 oldmode=physical_mode;
 fork
  sensor_word(value);
  begin request(nextmode);ce=0;consume(value,oldmode,nextmode,0,seq);seq=seq+1;end
 join
 if(physical_mode!=nextmode||physical_pulses!=25+nextmode)$fatal(1,"next physical gain");
end endtask
task queue_word;input[23:0]value;input integer nextmode;integer before_completed;begin
 before_completed=completed_count;
 fork sensor_word(value);begin request(nextmode);ce=0;while(completed_count==before_completed)tick;ce=1;end join
 if(physical_pulses!=25+nextmode||physical_mode!=nextmode)$fatal(1,"full FIFO changed physical gain");seq=seq+1;
end endtask
integer i,oldr,oldf;time pdstart;reg[23:0]data;
initial begin
 repeat(4)tick;rst_n=1;pdstart=$time;ce=0;
 while(pd_sck!==0)tick;
 if($time-pdstart<61000)$fatal(1,"startup not physical reset");ce=1;ready_idle;
 // Ordered adjacent mode pairs include all nine combinations, with signed boundaries.
 sample(24'h000000,0);sample(24'h7fffff,0);sample(24'h800000,1);sample(24'hffffff,0);sample(24'h123456,2);
 sample(24'haa55ff,1);sample(24'h808080,1);sample(24'h010203,2);sample(24'hfedcba,2);sample(24'h765432,0);
 // Invalid selection and ready timeout must produce zero physical clock edges.
 oldr=rises;dout=1;request(3);consume(0,0,3,1,seq);seq=seq+1;if(rises!=oldr)$fatal(1,"invalid clocks");
 request(2);ce=0;consume(0,0,2,2,seq);seq=seq+1;if(rises!=oldr||timeout_count!=1)$fatal(1,"timeout physical clocks");
 // Explicit idle powerdown remains asserted with CE0, then wakes to A128.
 ready_idle;ce=0;power_down=1;tick;pdstart=last_rise;repeat(@PDWAIT@)tick;
 if(!powered_down||!pd_sck||$time-pdstart<80000||out_valid)$fatal(1,"explicit PD policy");
 power_down=0;ce=1;ready_idle;sample(24'h800001,2);
 // Abort while a real high pulse is underway intentionally powercycles and reports error3.
 dout=0;request(1);@(posedge pd_sck);tick;abort=1;tick;abort=0;dout=1;
 consume(0,2,1,3,seq);seq=seq+1;ready_idle;sample(24'hffffff,1);
 // Explicit powerdown during WAIT_READY reports error4 and preserves prior mode tag.
 dout=1;request(2);power_down=1;tick;consume(0,1,2,4,seq);seq=seq+1;
 while(!powered_down)tick;repeat(@PDWAIT@)tick;power_down=0;ready_idle;sample(24'h000001,0);
 // A full output FIFO must drop the newest result without stretching SCK or
 // corrupting held older packets. The physical ADC still adopts its new gain.
 i=seq;queue_word(24'h123abc,1);queue_word(24'h987654,2);queue_word(24'h812345,0);
 if(dropped_count!=1)$fatal(1,"FIFO drop-new accounting");
 while(!out_valid)tick;if(out_sequence!=i||out_data!==24'h123abc||out_mode!=0||out_next_mode!=1||out_error)$fatal(1,"FIFO old head");
 out_ready=0;ce=0;repeat(11)tick;if(out_sequence!=i||out_data!==24'h123abc)$fatal(1,"FIFO held head");
 out_ready=1;tick;out_ready=0;
 consume(24'h987654,1,2,0,i+1);ce=1;sample(24'h800000,1);
 if(accepted_count!=seq||completed_count!=seq||dropped_count!=1||words!=17||signed_negative<5||powercycles!=4)$fatal(1,"accounting");
 ce=0;rst_n=0;tick;if(!pd_sck||!powered_down||out_valid||accepted_count||completed_count||timeout_count)$fatal(1,"reset CE0");
 $display("PASS HX711_PHYSICAL CLOCK=@CLOCK@ HIGH=@HIGH@ words=%0d seq=%0d signednegative=%0d physicalpowercycles=%0d maxnormalhigh=%0t",words,seq,signed_negative,powercycles,maximum_normal_high);$finish;
end
initial begin #100000000;$fatal(1,"watchdog");end
endmodule"""
def main():
 reference=json.loads((H/'datasheet_reference.json').read_text(encoding='utf-8'));assert reference['status']=='FETCHED_INDEPENDENTLY' and reference['pdf_sha256']=='6050e88a5e938ff9ac3292bfbc9fea2afa0ca73d1a649d5398ae8de5ab7c017e'
 before=sha(O/'hx711_adc.sv');freeze_path=O/'source_freeze.json';freeze=sha(freeze_path) if freeze_path.exists() else None
 frozen=json.loads(freeze_path.read_text(encoding='utf-8')) if freeze else None
 if freeze:assert len(frozen)==11 and all(sha(O/n)==v for n,v in frozen.items()),'owner freeze invalid before simulation'
 rows=[]
 for clock,high,low in [(1000000,1000,1000),(50000000,200,200),(1000000,49000,2000)]:
  tb=TB
  # Quiet detection exceeds the configured low interval plus physical-clock FSM overhead.
  for k,v in dict(CLOCK=clock,HALF=500000000//clock,HIGH=high,LOW=low,GAP=low+5000000000//clock,PDWAIT=(clock*100)//1000000).items():tb=tb.replace('@'+k+'@',str(v))
  label=f'c{clock}_h{high}'
  with tempfile.TemporaryDirectory(prefix='hx711_physical_peer_') as td:
   p=Path(td);(p/'tb.sv').write_text(tb,encoding='utf-8');execute(['iverilog','-g2012','-s','tb','-o',p/'sim',O/'hx711_adc.sv',p/'tb.sv'],p,H/f'compile_{label}.log');out=execute(['vvp',p/'sim'],p,H/f'simulation_{label}.log');assert 'PASS HX711_PHYSICAL' in out
  rows.append(dict(clock_hz=clock,high_ns=high,low_ns=low,status='PASS',output=out,log=f'simulation_{label}.log',log_sha256=sha(H/f'simulation_{label}.log')));print(out,flush=True)
 assert before==sha(O/'hx711_adc.sv'),'owner RTL changed during run'
 if freeze:assert freeze==sha(freeze_path) and all(sha(O/n)==v for n,v in frozen.items())
 resources=[];synthesis=json.loads((O/'synthesis_evidence.json').read_text(encoding='utf-8'))
 assert synthesis['status']=='PASS' and synthesis['rtl_sha256']==before and len(synthesis['profiles'])==2
 for row in synthesis['profiles']:
  log=O/row['log'];assert sha(log)==row['log_sha256'];text=log.read_text(encoding='utf-8');assert 'Executing CHECK pass' in text and 'Found and reported 0 problems.' in text
  marker='=== hx711_adc ===';assert marker in text
  cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Z][A-Z0-9_]*)\s*$',text[text.rfind(marker):],re.M)}
  assert cells=={k:v for k,v in row['cells'].items() if k not in ('wires','ports','cells')}
  dspcell=lambda k:'DSP' in k or 'MULT' in k or k in ('ALU54D','PADD9','PADD18')
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')) and not dspcell(k))+4*cells.get('RAM16SDP4',0)
  dsp=sum(v for k,v in cells.items() if dspcell(k));bram9=2*sum(v for k,v in cells.items() if k in ('SP','SPX9','DPB','DPX9B','SDPB','SDPX9B','ROM','ROMX9'))
  assert (lut,dsp)==(row['lut_class'],row['dsp']) and lut<=15000 and dsp<=4 and bram9<=46
  resources.append(dict(profile=row['profile'],log=row['log'],log_sha256=sha(log),lut_class=lut,dsp=dsp,bram9=bram9))
 assert before==sha(O/'hx711_adc.sv') and (not freeze or (freeze==sha(freeze_path) and all(sha(O/n)==v for n,v in frozen.items())))
 result=dict(status='PASS' if freeze else 'DEVELOPMENT_PASS_NOT_FROZEN',source_freeze_sha256=freeze,owner_frozen_inputs=frozen,rtl_sha256=before,peer_script_sha256=sha(Path(__file__)),peer_input_sha256={Path(__file__).name:sha(Path(__file__)), 'datasheet_reference.json':sha(H/'datasheet_reference.json')},datasheet=reference,profiles=rows,resources=resources,findings=[],scope='Independent actual pin waveform and signed-data scoreboard; no owner device model, no JTAG/UART/board access')
 (H/'peer_review_hx711.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
