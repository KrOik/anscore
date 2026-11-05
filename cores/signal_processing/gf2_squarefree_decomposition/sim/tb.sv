// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb;
 parameter integer D=16,TAG_W=8;
 localparam integer IW=(D>1)?$clog2(D+1):1;
 localparam integer LMAX=(D<2)?0:$clog2(D+1)-1;
 localparam integer LW=(LMAX>0)?$clog2(LMAX+1):1;
 localparam integer PW=8*(D+1)+TAG_W+IW+LW+2;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,s_valid=0,m_ready=0;
 reg [D-1:0] s_poly=0;reg [TAG_W-1:0] s_tag=0;
 wire s_ready,m_valid,m_last;
 wire [D:0] m_factor;wire [IW-1:0] m_multiplicity,m_degree;
 wire [TAG_W-1:0] m_tag;
 gf2_squarefree_decomposition #(.DEGREE(D),.TAG_W(TAG_W)) dut(.*);
 integer mode,fd,n,header_d,header_t,rc,ch,j,k,cycle=0;
 integer accepts=0,completed=0,canceled=0,factors=0,prefix_factors=0,fresh_factors=0;
 integer source_holds=0,output_holds=0,latency_checks=0,reset_offers=0,next_probes=0,reset_jobs=0;
 integer gcd_cancels=0,gcd_swaps=0,gcd_done=0,div_cancels=0,div_done=0,roots=0;
 reg started=0,pending=0,seen=0,in_blocked=0,out_blocked=0,owner_mode=0;
 integer src_slot=0,src_id=0,src_phase=0,owner_slot=0,owner_id=0,owner_phase=0;
 integer part=0,base_cycle=0,observed_gap=0,hold_wait=0;
 reg [63:0] cp[0:63],ct[0:63];integer cn[0:63];
 reg [64:0] cf[0:4095];integer ce[0:4095],cd[0:4095],cl[0:4095],cg[0:4095];
 reg [63:0] scan_poly,scan_tag;reg [64:0] scan_factor;
 integer scan_count,scan_exp,scan_degree,scan_last,scan_gap;
 integer probe_id,next_offer,target_mask,target_state,target_operation,target_iteration,target_level,target_prefix,target_last;
 reg [64:0] target_u,target_v,target_q,target_c,target_w,target_z;
 reg [D-1:0] held_in_poly;reg [TAG_W-1:0] held_in_tag;
 reg [D+TAG_W+2*IW+1:0] held_out;
 wire [D+TAG_W+2*IW+1:0] packed_out={m_factor,m_multiplicity,m_degree,m_last,m_tag};
 wire [PW-1:0] payload={dut.f,dut.c,dut.w,dut.y,dut.z,dut.u,dut.v,dut.q,dut.iteration,dut.level,dut.tag,dut.operation};
 reg [PW-1:0] reset_payload;
 reg [64:0] prior_u,prior_v,prior_q,prior_c,prior_w;
 integer prior_state,prior_operation,prior_du,prior_dv,prior_level;
 reg [1023:0] filename;

 function integer deg(input reg [64:0] x);
  integer b;begin deg=-1;for(b=0;b<=64;b=b+1)if(x[b])deg=b;end
 endfunction
 function [64:0] root_poly(input reg [64:0] x);
  integer b;begin root_poly=0;for(b=0;b<=32;b=b+1)root_poly[b]=x[2*b];end
 endfunction
 task read_command(input integer slot);
  integer b,index;
  begin
   rc=$fscanf(fd,"%h %h %d",scan_poly,scan_tag,scan_count);
   if(rc!=3 || scan_count<1 || scan_count>D)$fatal(1,"command fixture scan");
   cp[slot]=scan_poly;ct[slot]=scan_tag;cn[slot]=scan_count;
   for(b=0;b<scan_count;b=b+1)begin
    rc=$fscanf(fd,"%h %d %d %d %d",scan_factor,scan_exp,scan_degree,scan_last,scan_gap);
    if(rc!=5)$fatal(1,"factor fixture scan");
    index=slot*64+b;cf[index]=scan_factor;ce[index]=scan_exp;cd[index]=scan_degree;cl[index]=scan_last;cg[index]=scan_gap;
   end
  end
 endtask
 task set_source(input integer slot,id,phase);
  begin
   src_slot=slot;src_id=id;src_phase=phase;
   s_poly=cp[slot][D-1:0];s_tag=ct[slot][TAG_W-1:0];s_valid=1;
  end
 endtask
 task send_command(input integer slot,id,phase);
  integer before_count;
  begin
   @(negedge clk);before_count=accepts;set_source(slot,id,phase);
   while(accepts==before_count)@(negedge clk);
   s_valid=0;
  end
 endtask
 task check_output;
  integer index;
  begin
   index=owner_slot*64+part;
   if(!pending || part>=cn[owner_slot])$fatal(1,"unowned factor");
   if(m_factor!==cf[index][D:0] || m_multiplicity!==ce[index][IW-1:0] || m_degree!==cd[index][IW-1:0] ||
      m_last!==cl[index][0] || m_tag!==ct[owner_slot][TAG_W-1:0])
      $fatal(1,"factor mismatch cmd=%0d part=%0d got=%h e=%0d degree=%0d last=%0d",owner_id,part,m_factor,m_multiplicity,m_degree,m_last);
  end
 endtask
 function predicate;
  begin
   predicate=pending && owner_phase==1 && (dut.state===target_state[2:0]) &&
     (dut.iteration===target_iteration[IW-1:0]) && (dut.level===target_level[LW-1:0]) && part==target_prefix;
   if(target_mask&1)predicate=predicate && (dut.operation===target_operation[1:0]);
   if(target_mask&2)predicate=predicate && (dut.u===target_u[D:0]) && (dut.v===target_v[D:0]);
   if(target_mask&4)predicate=predicate && (dut.q===target_q[D:0]);
   if(target_mask&8)predicate=predicate && (dut.c===target_c[D:0]) && (dut.w===target_w[D:0]);
   if(target_mask&16)predicate=predicate && (dut.z===target_z[D:0]);
   if(target_mask&32)predicate=predicate && (m_last===target_last[0]);
  end
 endfunction

 always @(negedge clk)begin
  if(rst || owner_mode && (!pending || part>=target_prefix))begin m_ready=0;hold_wait=0;end
  else if(mode==0)m_ready=1;
  else if(!m_valid)begin m_ready=0;hold_wait=0;end
  else if(hold_wait<3)begin m_ready=0;hold_wait=hold_wait+1;end
  else m_ready=1;
 end

 always @(posedge clk)begin
  cycle=cycle+1;if(cycle>5000000)$fatal(1,"fixed cycle watchdog");
  prior_state=dut.state;prior_operation=dut.operation;prior_u=dut.u;prior_v=dut.v;prior_q=dut.q;
  prior_du=dut.degree_u;prior_dv=dut.degree_v;prior_c=dut.c;prior_w=dut.w;prior_level=dut.level;
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
    if(pending)$fatal(1,"accepted while frame owns core");
    pending=1;seen=0;part=0;base_cycle=cycle;accepts=accepts+1;
    owner_slot=src_slot;owner_id=src_id;owner_phase=src_phase;
   end
   if(m_valid && m_ready)begin
    if(!seen)$fatal(1,"factor retired without first-valid check");check_output();
    $display("REC cmd=%0d phase=%0d part=%0d poly=%h tag=%h factor=%h multiplicity=%0d degree=%0d last=%0d gap=%0d",owner_id,owner_phase,part,cp[owner_slot],m_tag,m_factor,m_multiplicity,m_degree,m_last,observed_gap);
    factors=factors+1;
    if(owner_phase==1)prefix_factors=prefix_factors+1;
    if(owner_phase==2)fresh_factors=fresh_factors+1;
    if(m_last)begin
     if(part!=cn[owner_slot]-1)$fatal(1,"early last");
     $display("FRAME cmd=%0d phase=%0d parts=%0d",owner_id,owner_phase,part+1);
     completed=completed+1;pending=0;
    end
    part=part+1;seen=0;base_cycle=cycle;
   end
   if(dut.state==2)begin
    if(dut.v==0)gcd_done=gcd_done+1;
    else if(dut.u==0 || dut.degree_u<dut.degree_v)gcd_swaps=gcd_swaps+1;
    else gcd_cancels=gcd_cancels+1;
   end
   if(dut.state==3)begin
    if(dut.v==0)$fatal(1,"zero exact-division divisor");
    if(dut.u==0 || dut.degree_u<dut.degree_v)begin
     if(dut.u!=0)$fatal(1,"nonzero exact-division remainder");div_done=div_done+1;
    end else div_cancels=div_cancels+1;
   end
   if(dut.state==4 && dut.w==1 && dut.c!=1)begin
    for(k=1;k<=D;k=k+2)if(dut.c[k]!==1'b0)$fatal(1,"root discards nonzero odd coefficient");
    roots=roots+1;
   end
  end
  #1;
  if(!rst)begin
   if(m_valid && pending && !seen)begin
    check_output();observed_gap=cycle-base_cycle;
    if(observed_gap!=cg[owner_slot*64+part])$fatal(1,"factor first-valid gap cmd=%0d part=%0d got=%0d expected=%0d",owner_id,part,observed_gap,cg[owner_slot*64+part]);
    seen=1;latency_checks=latency_checks+1;
   end
   if(prior_state==2 && prior_v!=0)begin
    if(prior_u==0 || prior_du<prior_dv)begin
     if(dut.u!==prior_v[D:0] || dut.v!==prior_u[D:0])$fatal(1,"GCD swap invariant");
    end else begin
     if(dut.v!==prior_v[D:0] || dut.u!==(prior_u[D:0]^(prior_v[D:0]<<(prior_du-prior_dv))))$fatal(1,"GCD cancellation invariant");
     if(dut.u!=0 && deg(dut.u)>=prior_du)$fatal(1,"GCD degree progress");
    end
   end
   if(prior_state==3 && prior_u!=0 && prior_du>=prior_dv)begin
    if(dut.u!==(prior_u[D:0]^(prior_v[D:0]<<(prior_du-prior_dv))) || dut.v!==prior_v[D:0] ||
       dut.q!==(prior_q[D:0]^({{D{1'b0}},1'b1}<<(prior_du-prior_dv))))$fatal(1,"division cancellation invariant");
    if(dut.u!=0 && deg(dut.u)>=prior_du)$fatal(1,"division degree progress");
   end
   if(prior_state==4 && prior_w==1 && prior_c!=1)begin
    if(dut.f!==root_poly(prior_c) || dut.level!=prior_level+1 || dut.iteration!=1)$fatal(1,"root transition invariant");
   end
  end
 end

 initial begin
  if(!$value$plusargs("MODE=%d",mode) || mode<0 || mode>2)$fatal(1,"MODE missing or invalid");
  if(!$value$plusargs("FILE=%s",filename))$fatal(1,"FILE missing");
  fd=$fopen(filename,"r");if(!fd)$fatal(1,"fixture open");
  rc=$fscanf(fd,"%d %d %d",n,header_d,header_t);
  if(rc!=3 || header_d!=D || header_t!=TAG_W || n<1 || n>64)$fatal(1,"fixture header");
  if(mode!=2)for(j=0;j<n;j=j+1)read_command(j);
  repeat(3)@(negedge clk);rst=0;started=1;
  if(mode!=2)begin
   for(j=0;j<n;j=j+1)send_command(j,j,0);
   while(completed<n)@(negedge clk);
   if(accepts!=n || canceled!=0)$fatal(1,"main frame conservation");
  end else begin
   for(j=0;j<n;j=j+1)begin
    rc=$fscanf(fd,"%d %d",probe_id,next_offer);if(rc!=2)$fatal(1,"probe header");
    read_command(0);read_command(1);
    rc=$fscanf(fd,"%d %d %d %d %d %d %d",target_mask,target_state,target_operation,target_iteration,target_level,target_prefix,target_last);
    if(rc!=7)$fatal(1,"predicate scalar scan");
    rc=$fscanf(fd,"%h %h %h %h %h %h",target_u,target_v,target_q,target_c,target_w,target_z);
    if(rc!=6)$fatal(1,"predicate polynomial scan");
    owner_mode=1;send_command(0,probe_id,1);
    while(!predicate())begin
     if(cycle-base_cycle>cn[0]*30000+1000)$fatal(1,"frozen predicate not reached id=%0d",probe_id);
     @(negedge clk);
    end
    $display("PROBE id=%0d state=%0d operation=%0d iteration=%0d level=%0d prefix=%0d u=%h v=%h q=%h c=%h w=%h z=%h last=%0d offer=%0d",probe_id,dut.state,
      (target_mask&1)?dut.operation:0,dut.iteration,dut.level,part,
      (target_mask&2)?dut.u:{(D+1){1'b0}},(target_mask&2)?dut.v:{(D+1){1'b0}},
      (target_mask&4)?dut.q:{(D+1){1'b0}},(target_mask&8)?dut.c:{(D+1){1'b0}},(target_mask&8)?dut.w:{(D+1){1'b0}},
      (target_mask&16)?dut.z:{(D+1){1'b0}},(target_mask&32)?m_last:0,next_offer);
    if(next_offer)begin
     if(!m_valid || m_ready || s_ready)$fatal(1,"actual next-offer setup");
     set_source(1,probe_id,2);
     repeat(3)begin @(negedge clk);if(!s_valid || s_ready || !m_valid || m_ready)$fatal(1,"actual next offer not held");end
     next_probes=next_probes+1;
    end else if(target_state==5)repeat(3)@(negedge clk);
    set_source(1,probe_id,2);reset_payload=payload;rst=1;
    repeat(3)@(negedge clk);
    if(payload!==reset_payload)$fatal(1,"reset changed arithmetic payload");
    rst=0;owner_mode=0;rc=accepts;
    while(accepts==rc)@(negedge clk);
    s_valid=0;
    while(completed<j+1)@(negedge clk);
    reset_jobs=reset_jobs+1;
   end
   if(accepts!=2*n || completed!=n || canceled!=n || reset_offers!=3*n || next_probes!=1)$fatal(1,"reset frame conservation");
  end
  ch=$fgetc(fd);
  while(ch!=-1)begin
   if(ch!=32 && ch!=9 && ch!=10 && ch!=13)$fatal(1,"trailing fixture byte");
   ch=$fgetc(fd);
  end
  $fclose(fd);repeat(2)@(negedge clk);
  if(pending || m_valid)$fatal(1,"tail not empty");
  $display("PASS mode=%0d D=%0d accepts=%0d completed=%0d canceled=%0d factors=%0d prefix=%0d fresh=%0d resets=%0d next=%0d reset_offers=%0d source_holds=%0d output_holds=%0d latency_checks=%0d gcd_cancels=%0d gcd_swaps=%0d gcd_done=%0d div_cancels=%0d div_done=%0d roots=%0d",mode,D,accepts,completed,canceled,factors,prefix_factors,fresh_factors,reset_jobs,next_probes,reset_offers,source_holds,output_holds,latency_checks,gcd_cancels,gcd_swaps,gcd_done,div_cancels,div_done,roots);
  $finish;
 end
endmodule
