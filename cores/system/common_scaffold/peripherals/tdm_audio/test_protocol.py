from run_tests import *
P=TB.split('initial begin')[0]
for k,v in dict(NS=4,SB=16,WB=12,DL=1,POL=1,PULSE=2).items():P=P.replace('@'+k+'@',str(v))
P=P.replace('reg got=', 'reg got=')
P+=r'''
integer frameval=0,z,n,errors,checks=0;reg enable_compare=1;
task step;input fsv;input dat;begin @(posedge bclk);#1;fs=fsv;sd=dat;@(negedge bclk);#1;end endtask
task resetall;begin @(posedge bclk);#1;rst_n=0;ce=0;fs=0;s_valid=0;sd=0;repeat(3)@(posedge bclk);#1;if(m_valid||tx_sd||overflow_count||framing_count||underrun_count||input_error_count)$fatal(1,"reset CE0");rst_n=1;ce=1;got=0;heldvalid=0;m_ready=0;end endtask
task frame;input integer value,width,length;integer x,r,sl,bt;reg d;reg[WB-1:0]v;begin
for(x=0;x<length;x=x+1)begin r=x-DL;sl=r/SB;bt=r%SB;v=value*NS+sl;d=r>=0&&bt<WB?v[WB-1-bt]:0;step(x<width,d);end end endtask
task expectframe;input integer ix,value;integer x;begin for(x=0;x<NS;x=x+1)rv[ix*NS+x]=value*NS+x;end endtask
task put;input integer slotnum,value;input first,last;begin
@(posedge bclk);#1;s_sample=value;s_slot=slotnum;s_sof=first;s_last=last;s_valid=1;
@(negedge bclk);while(!s_ready)@(negedge bclk);#1;s_valid=0;end endtask
task clear_errors;begin @(posedge bclk);#1;ce=0;error_clear=1;repeat(3)@(posedge bclk);#1;if(!overflow_sticky&&!framing_sticky&&!input_error_sticky&&!underrun_sticky)$fatal(1,"CE0 cleared errors");ce=1;repeat(2)@(posedge bclk);#1;error_clear=0;if(overflow_sticky||framing_sticky||input_error_sticky||underrun_sticky)$fatal(1,"clear error");checks=checks+1;end endtask
initial begin
resetall;
for(z=0;z<3;z=z+1)expectframe(z,z);
ce=0;m_ready=0;for(z=0;z<6;z=z+1)frame(z,2,FB);
step(1,0);step(1,0);step(0,0); // seventh FS commits sixth frame, overflow3
if(overflow_count!=3||!overflow_sticky||framing_count)$fatal(1,"overflow count %d",overflow_count);
ce=1;m_ready=1;repeat(20)step(0,0);
if(got!=12)$fatal(1,"old frame order/capacity %d",got);checks=checks+1;clear_errors;
resetall;
// Bad pulse, short frame, missing FS, stuck-active FS, then clean reacquisition.
frame(9,1,FB);frame(10,2,FB); // short pulse invalidates9;10 is valid pending
expectframe(0,10);m_ready=0;frame(11,2,FB-3); //11 period short at next boundary
frame(12,2,FB+2); // missing expected next FS:12 must drop
frame(13,FB,FB+2); // stuck pulse plus missing FS
expectframe(1,14);m_ready=1;frame(14,2,FB);frame(15,2,NS*3+4);
if(got!=8||framing_count<4||!framing_sticky||!tx_framing_sticky)$fatal(1,"framing/recovery got%d RXerr%d TXerr%d",got,framing_count,tx_framing_count);checks=checks+1;clear_errors;
resetall;
put(0,100,1,0);put(2,102,0,0); // broken slot sequence
if(input_error_count!=1||!input_error_sticky)$fatal(1,"marker sequence");
put(0,200,1,0);put(0,300,1,0); // newSOF restarts partial frame immediately
for(z=1;z<NS;z=z+1)put(z,300+z,0,z==NS-1);
if(input_error_count!=2)$fatal(1,"SOF restart");
for(z=0;z<2*NS;z=z+1)put(z%NS,400+z,z%NS==0,z%NS==NS-1);
if(s_ready)$fatal(1,"TX queue unbounded");
ce=0;s_valid=1;s_sample=999;s_slot=0;s_sof=1;s_last=0;
repeat(5)@(negedge bclk);#1;if(tx.in_slot!=0||input_error_count!=2)$fatal(1,"CE0 input consumed");s_valid=0;
// Three queued frames serialized correctly despite CE0, then entire zero-filled frame.
for(n=0;n<4;n=n+1)for(z=0;z<FB;z=z+1)begin
rel=z-1;slot=rel/SB;bitno=rel%SB;
if(n==0)frameval=300+slot;else if(n<3)frameval=400+(n-1)*NS+slot;else frameval=0;
expected=rel>=0&&bitno<WB?((frameval>>(WB-1-bitno))&1):0;
step(z<2,0);if(tx_sd!==expected)$fatal(1,"TX marker recover frame%d bit%d",n,z);
end
if(underrun_count!=1||!underrun_sticky)$fatal(1,"underflow");checks=checks+1;clear_errors;
// A partially assembled input frame cannot leak a mixture onto the wire.
resetall;put(0,123,1,0);put(1,456,0,0);ce=0;
for(z=0;z<FB;z=z+1)begin step(z<2,0);if(tx_sd!==0)$fatal(1,"partial frame leaked");end
if(underrun_count!=1||tx.in_slot!=2)$fatal(1,"partial fill accounting");checks=checks+1;
// reset in middle of physical and partial input clears pending state independently of CE.
resetall;if(tx.pending_valid||tx.count||rx.count||tx.in_slot)$fatal(1,"reset partial");checks=checks+1;
$display("PASS TDM PROTOCOL checks=%0d overflow/recovery, pulse/period/loss/stuck, marker recovery, CE0, FIFO bounds, zero fill, reset",checks);$finish;
end
endmodule'''
def main():
 out=sim('protocol',P);print(out);(H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),scope='Directed physical framing errors and recovery, RX complete-frame overflow/order/capacity, TX slot/SOF input errors and restart, CE0 gates handshakes only, bounded queue, underrun all-zero frame, sticky clear and CE0 reset',output=out),indent=2)+'\n')
if __name__=='__main__':main()
