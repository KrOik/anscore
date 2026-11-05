// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb;
 parameter integer D=16,TAG_W=8;
 localparam integer IW=(D>1)?$clog2(D+1):1;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,s_valid=0,m_ready=0;
 wire s_ready,m_valid,m_irreducible;
 reg [D-1:0] s_poly=0;reg [TAG_W-1:0] s_tag=0;
 wire [1:0] m_kind;wire [IW-1:0] m_check_index;
 wire [D-1:0] m_delta;wire [D:0] m_witness_gcd;
 wire [TAG_W-1:0] m_tag;
 gf2_polynomial_irreducibility #(.DEGREE(D),.TAG_W(TAG_W)) dut(.*);
 integer mode,fd,n,header_d,header_t,j,rc,ch,cycle=0;
 integer accepts=0,outputs=0,canceled=0,source_holds=0,output_holds=0;
 integer squares=0,gcd_cancel=0,gcd_swap=0,gcd_done=0,latency_checks=0;
 integer reset_offers=0,next_probes=0,reset_jobs=0,hold_wait=0;
 reg started=0,owner_phase=0,pending=0,seen=0,in_blocked=0,out_blocked=0;
 integer accepted_cycle=0,owner_id=0,src_id=0;
 reg [63:0] src_poly=0,src_tag=0,owner_poly,owner_tag;
 integer src_irred,src_kind,src_index,src_cycles;
 reg [63:0] src_delta;reg [64:0] src_gcd;
 integer owner_irred,owner_kind,owner_index,owner_cycles;
 reg [63:0] owner_delta;reg [64:0] owner_gcd;
 reg [D-1:0] held_in_poly;reg [TAG_W-1:0] held_in_tag;
 reg [D+TAG_W+D+1+IW+2:0] held_out;
 wire [D+TAG_W+D+1+IW+2:0] packed_out={m_irreducible,m_kind,m_check_index,m_delta,m_witness_gcd,m_tag};
 reg [63:0] ap[0:511],at[0:511],ad[0:511];reg [64:0] ag[0:511];
 integer ai[0:511],ak[0:511],ax[0:511],ac[0:511];
 reg [63:0] qp,qt,qd,fp,ft,fdlt;reg [64:0] qg,fg;
 integer qi,qk,qx,qc,fi,fk,fx,fc;
 integer probe_id,next_offer,target_state,target_k,target_left,target_mask;
 reg [64:0] target_u,target_v;
 reg [64:0] prior_u,prior_v;integer prior_du,prior_dv,prior_state;
 reg [1023:0] filename;

 function integer deg(input reg [64:0] x);
  integer k;begin deg=-1;for(k=0;k<=64;k=k+1)if(x[k])deg=k;end
 endfunction
 task read_record(output reg [63:0] p,t,output integer ir,k,ix,
                  output reg [63:0] delta,output reg [64:0] g,output integer cycles);
  begin
   rc=$fscanf(fd,"%h %h %d %d %d %h %h %d",p,t,ir,k,ix,delta,g,cycles);
   if(rc!=8)$fatal(1,"fixture record scan %0d",rc);
  end
 endtask
 task set_source(input reg [63:0] p,t,input integer ir,k,ix,
                  input reg [63:0] delta,input reg [64:0] g,input integer cycles,id);
  begin
   src_poly=p;src_tag=t;src_irred=ir;src_kind=k;src_index=ix;
   src_delta=delta;src_gcd=g;src_cycles=cycles;src_id=id;
   s_poly=p[D-1:0];s_tag=t[TAG_W-1:0];s_valid=1;
  end
 endtask
 task send_record(input reg [63:0] p,t,input integer ir,k,ix,
                  input reg [63:0] delta,input reg [64:0] g,input integer cycles,id);
  integer before_count;
  begin
   @(negedge clk);before_count=accepts;set_source(p,t,ir,k,ix,delta,g,cycles,id);
   while(accepts==before_count)@(negedge clk);
   s_valid=0;
  end
 endtask
 function predicate;
  begin
   predicate=dut.state==target_state;
   if(target_mask&1)predicate=predicate && dut.round_index==target_k;
   if(target_mask&2)predicate=predicate && dut.square_left==target_left;
   if(target_mask&4)predicate=predicate && dut.u==target_u && dut.v==target_v;
  end
 endfunction

 always @(negedge clk)begin
  if(rst || owner_phase)begin m_ready=0;hold_wait=0;end
  else if(mode==0)m_ready=1;
  else if(!m_valid)begin m_ready=0;hold_wait=0;end
  else if(hold_wait<3)begin m_ready=0;hold_wait=hold_wait+1;end
  else m_ready=1;
 end

 always @(posedge clk)begin
  cycle=cycle+1;
  if(cycle>1000000)$fatal(1,"fixed cycle watchdog");
  prior_u=dut.u;prior_v=dut.v;prior_du=dut.degree_u;prior_dv=dut.degree_v;prior_state=dut.state;
  if(rst)begin
   if(s_ready || m_valid)$fatal(1,"reset handshake mask");
   if(started && s_valid)reset_offers=reset_offers+1;
   if(pending)begin canceled=canceled+1;pending=0;end
   seen=0;in_blocked=0;out_blocked=0;
  end else begin
   if(in_blocked && (!s_valid || s_poly!==held_in_poly || s_tag!==held_in_tag))$fatal(1,"source hold");
   if(out_blocked && (!m_valid || packed_out!==held_out))$fatal(1,"output hold");
   in_blocked=s_valid&&!s_ready;held_in_poly=s_poly;held_in_tag=s_tag;
   out_blocked=m_valid&&!m_ready;held_out=packed_out;
   if(in_blocked)source_holds=source_holds+1;
   if(out_blocked)output_holds=output_holds+1;
   if(s_valid && s_ready)begin
    if(pending)$fatal(1,"accepted while owner exists");
    pending=1;seen=0;accepts=accepts+1;accepted_cycle=cycle;
    owner_poly=src_poly;owner_tag=src_tag;owner_irred=src_irred;owner_kind=src_kind;
    owner_index=src_index;owner_delta=src_delta;owner_gcd=src_gcd;owner_cycles=src_cycles;owner_id=src_id;
   end
   if(m_valid && m_ready)begin
    if(!pending || !seen)$fatal(1,"unowned output");
    if(m_irreducible!==owner_irred[0] || m_kind!==owner_kind[1:0] || m_check_index!==owner_index[IW-1:0] ||
       m_delta!==owner_delta[D-1:0] || m_witness_gcd!==owner_gcd[D:0] || m_tag!==owner_tag[TAG_W-1:0])
       $fatal(1,"output mismatch id=%0d poly=%h kind=%0d index=%0d delta=%h gcd=%h",owner_id,owner_poly,m_kind,m_check_index,m_delta,m_witness_gcd);
    $display("REC id=%0d poly=%h tag=%h irred=%0d kind=%0d index=%0d delta=%h gcd=%h latency=%0d",owner_id,owner_poly,m_tag,m_irreducible,m_kind,m_check_index,m_delta,m_witness_gcd,owner_cycles);
    outputs=outputs+1;pending=0;
   end
   if(dut.state==2)squares=squares+1;
   if(dut.state==5)begin
    if(dut.v==0)gcd_done=gcd_done+1;
    else if(dut.u==0 || dut.degree_u<dut.degree_v)gcd_swap=gcd_swap+1;
    else gcd_cancel=gcd_cancel+1;
   end
  end
  #1;
  if(!rst)begin
   if(m_valid && pending && !seen)begin
    if(cycle-accepted_cycle!=owner_cycles)$fatal(1,"first valid latency id=%0d got=%0d expected=%0d",owner_id,cycle-accepted_cycle,owner_cycles);
    seen=1;latency_checks=latency_checks+1;
   end
   if(prior_state==5 && prior_v!=0)begin
    if(prior_u==0 || prior_du<prior_dv)begin
     if(dut.u!==prior_v[D:0] || dut.v!==prior_u[D:0])$fatal(1,"GCD swap invariant");
    end else begin
     if(dut.v!==prior_v[D:0] || dut.u!==(prior_u[D:0]^(prior_v[D:0]<<(prior_du-prior_dv))))$fatal(1,"GCD cancellation invariant");
     if(dut.u!=0 && deg(dut.u)>=prior_du)$fatal(1,"GCD degree did not decrease");
    end
   end
  end
 end

 initial begin
  if(!$value$plusargs("MODE=%d",mode))$fatal(1,"MODE missing");
  if(!$value$plusargs("FILE=%s",filename))$fatal(1,"FILE missing");
  fd=$fopen(filename,"r");if(!fd)$fatal(1,"fixture open");
  rc=$fscanf(fd,"%d %d %d",n,header_d,header_t);
  if(rc!=3 || header_d!=D || header_t!=TAG_W || n<1 || n>512)$fatal(1,"fixture header");
  if(mode!=2)begin
   for(j=0;j<n;j=j+1)begin
    read_record(qp,qt,qi,qk,qx,qd,qg,qc);
    ap[j]=qp;at[j]=qt;ai[j]=qi;ak[j]=qk;ax[j]=qx;ad[j]=qd;ag[j]=qg;ac[j]=qc;
   end
  end
  repeat(3)@(negedge clk);rst=0;started=1;
  if(mode!=2)begin
   for(j=0;j<n;j=j+1)send_record(ap[j],at[j],ai[j],ak[j],ax[j],ad[j],ag[j],ac[j],j);
   while(outputs<n)@(negedge clk);
   if(accepts!=n || canceled!=0 || latency_checks!=n)$fatal(1,"main conservation");
  end else begin
   for(j=0;j<n;j=j+1)begin
    rc=$fscanf(fd,"%d %d",probe_id,next_offer);if(rc!=2)$fatal(1,"probe header");
    read_record(qp,qt,qi,qk,qx,qd,qg,qc);read_record(fp,ft,fi,fk,fx,fdlt,fg,fc);
    rc=$fscanf(fd,"%d %d %d %h %h %d",target_state,target_k,target_left,target_u,target_v,target_mask);
    if(rc!=6)$fatal(1,"predicate scan");
    owner_phase=1;send_record(qp,qt,qi,qk,qx,qd,qg,qc,1000+probe_id);
    while(!predicate())begin
     if(cycle-accepted_cycle>owner_cycles+2)$fatal(1,"frozen predicate not reached id=%0d",probe_id);
     @(negedge clk);
    end
    if(!pending)$fatal(1,"probe lacks actual owner");
    $display("PROBE id=%0d state=%0d k=%0d left=%0d u=%h v=%h next=%0d",probe_id,dut.state,dut.round_index,
      (target_mask&2)?dut.square_left:0,(target_mask&4)?dut.u:{(D+1){1'b0}},(target_mask&4)?dut.v:{(D+1){1'b0}},next_offer);
    if(next_offer)begin
     if(!m_valid || m_ready || s_ready)$fatal(1,"actual next-offer setup");
     set_source(fp,ft,fi,fk,fx,fdlt,fg,fc,probe_id);
     repeat(3)begin @(negedge clk);if(!s_valid || s_ready || !m_valid || m_ready)$fatal(1,"next-offer not blocked");end
     next_probes=next_probes+1;
    end else if(target_state==6)repeat(3)@(negedge clk);
    // Three actual reset-high offers cannot be accepted, including D=1.
    set_source(fp,ft,fi,fk,fx,fdlt,fg,fc,probe_id);rst=1;
    repeat(3)@(negedge clk);
    rst=0;owner_phase=0;rc=accepts;
    while(accepts==rc)@(negedge clk);
    s_valid=0;
    while(outputs<j+1)@(negedge clk);
    reset_jobs=reset_jobs+1;
   end
   if(accepts!=2*n || outputs!=n || canceled!=n || reset_offers!=3*n || next_probes!=1)$fatal(1,"reset conservation");
  end
  ch=$fgetc(fd);
  while(ch!=-1)begin
   if(ch!=32 && ch!=9 && ch!=10 && ch!=13)$fatal(1,"trailing fixture byte");
   ch=$fgetc(fd);
  end
  $fclose(fd);
  repeat(2)@(negedge clk);
  if(pending || m_valid)$fatal(1,"tail not empty");
  $display("PASS mode=%0d D=%0d accepts=%0d outputs=%0d canceled=%0d resets=%0d next=%0d reset_offers=%0d source_holds=%0d output_holds=%0d squares=%0d gcd_cancel=%0d gcd_swap=%0d gcd_done=%0d latency_checks=%0d",mode,D,accepts,outputs,canceled,reset_jobs,next_probes,reset_offers,source_holds,output_holds,squares,gcd_cancel,gcd_swap,gcd_done,latency_checks);
  $finish;
 end
endmodule
