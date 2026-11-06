// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_payload_multiflow_token_shaper;
 parameter integer F=3,D=16,B=5,T=4,G=3,Q=3;
 localparam integer K=D/8,MAX_BYTES=B*K,BOUND=16*B+4096;
 reg clk=0;always #5 clk=~clk;
 reg rst=1;
 reg cv=0,ce=0,rr=0,sv=0,sl=0,ar=0,mr=0;
 reg [31:0] cf=0,sf=0;
 reg [T-1:0] cc=0,cr=0,ci=0;
 reg [G-1:0] ct=0,st=0;
 reg [D-1:0] sd=0;
 reg [K-1:0] sk=0;
 wire cready,rv,sready,av,mv,ms,ml,fault;
 wire [1:0] rs;
 wire [2:0] ast;
 wire [31:0] rf,af,ab,an,mf;
 wire [G-1:0] rt,at,mt;
 wire [D-1:0] md;
 wire [K-1:0] mk;
 wire [T-1:0] mb;
 payload_multiflow_token_shaper #(.FLOWS(F),.DATA_W(D),.MAX_BEATS(B),
  .TOKEN_W(T),.TAG_W(G),.QUANTUM(Q)) dut(
  .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cready),.c_flow(cf),.c_enable(ce),
  .c_capacity(cc),.c_rate(cr),.c_initial(ci),.c_tag(ct),.r_valid(rv),.r_ready(rr),
  .r_status(rs),.r_flow(rf),.r_tag(rt),.s_valid(sv),.s_ready(sready),.s_flow(sf),
  .s_data(sd),.s_keep(sk),.s_last(sl),.s_tag(st),.a_valid(av),.a_ready(ar),
  .a_status(ast),.a_flow(af),.a_bytes(ab),.a_beats(an),.a_tag(at),
  .m_valid(mv),.m_ready(mr),.m_flow(mf),.m_data(md),.m_keep(mk),
  .m_sop(ms),.m_last(ml),.m_length(mb),.m_tag(mt),.faulted(fault));

 integer fd,got,hf,hd,hb,ht,hg,hq,ncases,case_id=0,phase=0;
 integer ids[0:11],lens[0:11],caps[0:11],rates[0:11],inits[0:11],ens[0:11];
 integer statuses[0:11],bytes[0:11],beats[0:11];
 reg [31:0] flows[0:11],input_flows[0:11][0:B];
 reg [G-1:0] tags[0:11],input_tags[0:11][0:B];
 reg [D-1:0] data[0:11][0:B];
 reg [K-1:0] keeps[0:11][0:B];
 integer lasts[0:11][0:B];
 integer i,j,vframes=0,vbeats=0,admissions=0,configurations=0;
 reg [D-1:0] scan_data;
 reg [K-1:0] scan_keep;
 reg [31:0] scan_flow;
 reg [G-1:0] scan_tag;
 integer scan_last;
 integer holds=0,blocked=0,reset_probes=0,recovery_frames=0,ledger_checks=0;
 integer resets=0,sop_charges=0,vector_mode=1,concurrent_rw=0;
 reg [1023:0] vector_path;
 reg [255:0] trailing_token;

 task fail(input [255:0] message);
  begin $display("FAIL case=%0d phase=%0d ingress=%0d tx=%0d issued=%0d valid=%0d %0s",
   case_id,phase,dut.ingress_state,dut.tx_busy,dut.tx_issued,mv,message);$fatal(1);end
 endtask
 task reset_now;
  begin
   rst=1;cv=0;sv=0;rr=0;ar=0;mr=0;resets=resets+1;
   repeat(3)@(posedge clk);
   @(negedge clk);rst=0;
   @(negedge clk); // Continuous ready paths settle before any driver starts.
  end
 endtask
 task configure(input [31:0] flow,input integer enable,cap,rate,initial_value,status);
  integer count;
  reg [G-1:0] tag;
  begin
   tag=configurations+1;
   @(negedge clk);cv=1;cf=flow;ce=enable;cc=cap;cr=rate;ci=initial_value;ct=tag;
   count=0;
   do begin @(posedge clk);count=count+1;if(count>BOUND)fail("config acceptance bound");end while(!cready);
   @(negedge clk);cv=0;
   count=0;
   while(!rv)begin @(negedge clk);count=count+1;if(count>BOUND)fail("config response bound");end
   repeat(3)begin
    if(!rv || rs!==status || rf!==flow || rt!==tag)fail("config held fields");
    @(negedge clk);
   end
   rr=1;count=0;do begin @(posedge clk);count=count+1;if(count>BOUND)fail("config ACK bound");end while(!rv);
   @(negedge clk);rr=0;configurations=configurations+1;
  end
 endtask
 task put(input [31:0] flow,input [G-1:0] tag,input [D-1:0] value,
          input [K-1:0] keep,input integer last_value);
  integer count;
  begin
   @(negedge clk);sv=1;sf=flow;st=tag;sd=value;sk=keep;sl=last_value;
   count=0;
   do begin @(posedge clk);count=count+1;if(count>BOUND)fail("input acceptance bound");end while(!sready);
   @(negedge clk);sv=0;
  end
 endtask
 task check_admission(input integer index);
  integer count;
  begin
   count=0;
   while(!av)begin @(negedge clk);count=count+1;if(count>BOUND)fail("admission bound");end
   repeat(3)begin
    if(!av || ast!==statuses[index] || af!==flows[index] || at!==tags[index] ||
      ab!==bytes[index] || an!==beats[index])fail("admission fields/hold");
    @(negedge clk);
   end
   ar=1;count=0;do begin @(posedge clk);count=count+1;if(count>BOUND)fail("admission ACK bound");end while(!av);
   @(negedge clk);ar=0;
   if(vector_mode)admissions=admissions+1;
  end
 endtask
 task send_case(input integer index);
  integer word;
  begin
   case_id=index;
   for(word=0;word<lens[index];word=word+1)begin
    if(mv && !dut.tx_busy)fail("output without packet ownership");
    put(input_flows[index][word],input_tags[index][word],data[index][word],
      keeps[index][word],lasts[index][word]);
   end
   check_admission(index);
  end
 endtask
 task receive_case(input integer index);
  integer word,count;
  begin
   case_id=index;
   for(word=0;word<lens[index];word=word+1)begin
    count=0;
    while(!mv)begin @(negedge clk);count=count+1;if(count>BOUND)fail("output wait bound");end
    repeat(3)begin
     if(!mv || mf!==flows[index] || mt!==tags[index] || md!==data[index][word] ||
       mk!==keeps[index][word] || ms!==(word==0) || ml!==(word==lens[index]-1) ||
       mb!==bytes[index])fail("payload/markers/held metadata");
     @(negedge clk);
    end
    mr=1;count=0;do begin @(posedge clk);count=count+1;if(count>BOUND)fail("output handshake bound");end while(!mv);
    @(negedge clk);mr=0;
    if(vector_mode)vbeats=vbeats+1;
   end
   if(vector_mode)vframes=vframes+1;else recovery_frames=recovery_frames+1;
  end
 endtask
 task fresh_recovery;
  begin
   configure(0,1,MAX_BYTES,0,MAX_BYTES,0);
   send_case(0);receive_case(0);
   repeat(8)begin @(negedge clk);if(mv || av || rv || fault)fail("stale result after recovery");end
  end
 endtask

 // An independent clock ledger is driven solely by public config ACKs and
 // public SOP handshakes. It does not observe descriptor retirement events.
 // Comparing the existing engine's balances proves wrapper wiring cannot
 // precharge on prefetch or defer charging until LAST.
 reg [63:0] ledger[0:F-1],lc[0:F-1],lr[0:F-1];
 reg [F-1:0] le=0;
 reg [63:0] saved_cap=0,saved_rate=0,saved_initial=0;
 reg saved_enable=0;
 integer tick_phase=0,p;
 reg [63:0] balance;
 reg cs_hold=0,ss_hold=0,mo_hold=0,ar_hold=0,rr_hold=0;
 reg [3*T+G+33:0] held_cs;
 reg [D+K+G+32:0] held_ss;
 reg [D+K+T+G+33:0] held_mo;
 reg [G+98:0] held_ar;
 reg [G+33:0] held_rr;
 always @(posedge clk)begin
  if(rst)begin
   tick_phase=0;le=0;cs_hold=0;ss_hold=0;mo_hold=0;ar_hold=0;rr_hold=0;
   saved_cap=0;saved_rate=0;saved_initial=0;saved_enable=0;
   for(p=0;p<F;p=p+1)begin ledger[p]=0;lc[p]=0;lr[p]=0;end
   #1;if(cready || sready || rv || av || mv)fail("reset public handshake mask");
  end else begin
   if(fault)fail("unexpected backend invariant fault");
   if(phase==1 && dut.ingress_state==1 && mv)fail("payload published before accepted LAST");
   if(dut.ingress_write && dut.read_fire && dut.write_flow!=dut.tx_flow)concurrent_rw=concurrent_rw+1;
   if(cs_hold && (!cv || {cf,ce,cc,cr,ci,ct}!==held_cs))fail("config source changed while blocked");
   if(ss_hold && (!sv || {sf,sd,sk,sl,st}!==held_ss))fail("input source changed while blocked");
   if(mo_hold && (!mv || {mf,md,mk,ms,ml,mb,mt}!==held_mo))fail("output changed while blocked");
   if(ar_hold && (!av || {ast,af,ab,an,at}!==held_ar))fail("admission response changed while held");
   if(rr_hold && (!rv || {rs,rf,rt}!==held_rr))fail("config response changed while held");
   cs_hold=cv&&!cready;held_cs={cf,ce,cc,cr,ci,ct};
   ss_hold=sv&&!sready;held_ss={sf,sd,sk,sl,st};
   mo_hold=mv&&!mr;held_mo={mf,md,mk,ms,ml,mb,mt};
   ar_hold=av&&!ar;held_ar={ast,af,ab,an,at};
   rr_hold=rv&&!rr;held_rr={rs,rf,rt};
   if(mo_hold)holds=holds+1;
   if(ss_hold || cs_hold)blocked=blocked+1;
   for(p=0;p<F;p=p+1)begin
    balance=ledger[p];
    if(tick_phase==Q-1 && le[p])balance=balance+lr[p];
    if(balance>lc[p])balance=lc[p];
    if(mv && mr && ms && mf==p)begin
     if(ledger[p]<mb)fail("SOP without full pre-edge packet credit");
     balance=balance-mb;sop_charges=sop_charges+1;
    end
    if(rv && rr && rs==0 && rf==p)begin
     lc[p]=saved_cap;lr[p]=saved_rate;le[p]=saved_enable;balance=saved_initial;
    end
    ledger[p]=balance;
   end
   if(cv && cready)begin saved_cap=cc;saved_rate=cr;saved_initial=ci;saved_enable=ce;end
   tick_phase=tick_phase==Q-1?0:tick_phase+1;
   #1;
   for(p=0;p<F;p=p+1)begin
    if(dut.u_shaper.tokens[p]!==ledger[p][T-1:0])fail("public-SOP token ledger mismatch");
    ledger_checks=ledger_checks+1;
   end
  end
 end

 integer probe,count;
 initial begin
  if(!$value$plusargs("vectors=%s",vector_path))$fatal(1,"missing vectors");
  fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"open vectors");
  got=$fscanf(fd,"%d %d %d %d %d %d %d\n",hf,hd,hb,ht,hg,hq,ncases);
  if(got!=7 || hf!=F || hd!=D || hb!=B || ht!=T || hg!=G || hq!=Q || ncases!=12)$fatal(1,"vector header");
  for(i=0;i<12;i=i+1)begin
   got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d\n",ids[i],flows[i],tags[i],lens[i],
    caps[i],rates[i],inits[i],ens[i],statuses[i],bytes[i],beats[i]);
   if(got!=11 || ids[i]!=i || lens[i]<1 || lens[i]>B+1)$fatal(1,"vector case");
   for(j=0;j<lens[i];j=j+1)begin
    got=$fscanf(fd,"%h %h %d %d %d\n",scan_data,scan_keep,scan_flow,scan_tag,scan_last);
    if(got!=5)$fatal(1,"vector body");
    data[i][j]=scan_data;keeps[i][j]=scan_keep;input_flows[i][j]=scan_flow;
    input_tags[i][j]=scan_tag;lasts[i][j]=scan_last;
   end
  end
  got=$fscanf(fd,"%s",trailing_token);
  if(got==1 || !$feof(fd))$fatal(1,"trailing vector token or incomplete EOF");
  $fclose(fd);
  reset_now();phase=1;
  configure(32'hffffffff,1,1,0,1,1);
  configure(0,1,0,0,0,2);
  for(i=0;i<8;i=i+1)begin
   configure(0,ens[i],caps[i],rates[i],inits[i],0);
   send_case(i);
   if(statuses[i]==0)receive_case(i);
   else repeat(6)begin @(negedge clk);if(mv)fail("rejected packet prefix published");end
  end
  phase=2;
  configure(0,1,caps[8],rates[8],inits[8],0);send_case(8);
  if(F>1)begin
   configure(1,1,caps[9],rates[9],inits[9],0);
   fork
    receive_case(8);
    send_case(9);
   join
   receive_case(9);
  end else begin
   receive_case(8);configure(0,1,caps[9],rates[9],inits[9],0);send_case(9);receive_case(9);
  end
  phase=3;
  configure(0,1,caps[10],rates[10],inits[10],0);send_case(10);
  if(F>1)begin
   repeat(8)begin @(negedge clk);if(mv)fail("zero-rate underfunded flow became eligible");end
   configure(1,1,caps[11],rates[11],inits[11],0);send_case(11);receive_case(11);
   if(dut.state[0]==0)fail("underfunded ownership disappeared");
  end else begin
   receive_case(10);configure(0,1,caps[11],rates[11],inits[11],0);send_case(11);receive_case(11);
  end
  reset_now();vector_mode=0;phase=4;
  for(probe=0;probe<5;probe=probe+1)begin
   configure(0,1,MAX_BYTES,0,MAX_BYTES,0);
   if(probe==0)begin
    put(0,~tags[0],~data[0][0],{K{1'b1}},0);
    if(dut.ingress_state!=1)fail("COLLECT reset predicate");
   end else if(probe==1)begin
    // Actual held config response, after accepting a known independent update.
    @(negedge clk);cv=1;cf=0;ce=1;cc=MAX_BYTES;cr=0;ci=MAX_BYTES;ct=~tags[0];
    count=0;do begin @(posedge clk);count=count+1;if(count>BOUND)fail("held config acceptance bound");end while(!cready);
    @(negedge clk);cv=0;
    if(!rv)fail("config response reset predicate");
   end else begin
    put(0,~tags[0],~data[0][0],{K{1'b1}},(probe!=4 || B==1));
    if(probe==4 && B>1)put(32'hffffffff,tags[0],~data[0][0],{K{1'b1}},1);
    count=0;
    while(!mv)begin @(negedge clk);count=count+1;if(count>BOUND)fail("held SOP reset wait");end
    if(probe==3)begin
     // A real blocked next packet and configuration remain offered until reset.
     sv=1;sf=0;st=tags[0];sd=data[0][0];sk=1;sl=1;
     cv=1;cf=0;ce=1;cc=MAX_BYTES;cr=0;ci=MAX_BYTES;ct=tags[0];
     repeat(4)begin @(negedge clk);if(sready || cready)fail("occupied flow admitted work");end
    end else if(probe==4 && B>1)begin
     mr=1;count=0;do begin @(posedge clk);count=count+1;if(count>BOUND)fail("output handshake bound");end while(!mv);
     @(negedge clk);mr=0;
     count=0;
     while(!mv)begin @(negedge clk);count=count+1;if(count>BOUND)fail("held continuation reset wait");end
     if(ms || !ml)fail("continuation reset predicate");
     // Retire the admission reply so it cannot explain blocked ingress.
     ar=1;count=0;
     do begin @(posedge clk);count=count+1;if(count>BOUND)fail("continuation admission ACK bound");end while(!av);
     @(negedge clk);ar=0;
     sv=1;sf=0;st=tags[0];sd=data[0][0];sk=1;sl=1;
     cv=1;cf=0;ce=1;cc=MAX_BYTES;cr=0;ci=MAX_BYTES;ct=tags[0];
     repeat(4)begin
      @(negedge clk);
      if(sready || cready || !mv || ms || !ml)fail("SOP-to-LAST flow ownership released early");
     end
    end
   end
   reset_now();reset_probes=reset_probes+1;fresh_recovery();
  end
  if(F>1 && B>=4 && concurrent_rw==0)fail("concurrent bank write/read not exercised");
  if(fault || reset_probes!=5 || recovery_frames!=5)$fatal(1,"final state");
  $display("B48_A_CORE_PASS cases=12 vector_frames=%0d vector_beats=%0d admissions=%0d reset_probes=%0d recovery_frames=%0d holds=%0d blocked=%0d ledger_checks=%0d sop_charges=%0d concurrent_rw=%0d",
   vframes,vbeats,admissions,reset_probes,recovery_frames,holds,blocked,ledger_checks,sop_charges,concurrent_rw);
  $finish;
 end
 initial begin #2000000;$fatal(1,"global bounded watchdog case=%0d phase=%0d",case_id,phase);end
endmodule
