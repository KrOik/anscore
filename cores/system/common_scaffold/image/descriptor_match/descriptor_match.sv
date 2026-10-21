// Exhaustive set matcher. All transfers require ce && valid && ready.
module descriptor_match #(
 parameter DESC_BITS=128, CAPACITY=16
)(
 input wire clk,rst_n,ce,
 input wire load_valid,load_reference,input wire [DESC_BITS-1:0] load_descriptor,
 input wire [47:0] load_metadata,input wire load_invalid,output wire load_ready,
 input wire start_valid,output wire start_ready,
 input wire [8:0] max_distance,min_gap,
 input wire ratio_enable,input wire [15:0] ratio_num,ratio_den,
 input wire release_valid,output wire release_ready,
 output reg [15:0] query_count,reference_count,
 output reg m_valid,input wire m_ready,
 output reg [15:0] m_query_index,m_reference_index,
 output reg [47:0] m_query_metadata,m_reference_metadata,
 output reg [8:0] m_best,m_second,
 output reg [3:0] m_reason,output reg done,error,
 output reg [3:0] error_code
);
 localparam LOAD=0,QREAD=1,QWAIT=2,RREAD=3,RWAIT=4,DIST=5,PRESENT=6,HOLD=7,FINISH=8;
 reg [3:0] state;
 reg [DESC_BITS+48:0] qmem[0:CAPACITY-1],rmem[0:CAPACITY-1];
 reg [DESC_BITS+48:0] qq,rq;
 reg [DESC_BITS-1:0] query;
 reg query_invalid;
 reg [15:0] qi,ri,best_index,valid_refs;
 reg [47:0] best_meta;
 reg [8:0] best,second,limit_snapshot,gap_snapshot;
 reg ren;reg [15:0] rn,rd;
 integer j; reg [8:0] distance;
 wire [24:0] ratio_left=best*rd,ratio_right=second*rn;
 assign load_ready=rst_n&&ce&&state==LOAD&&!start_valid;
 assign start_ready=rst_n&&ce&&state==LOAD;
 assign release_ready=rst_n&&ce&&state==FINISH;
 always @* begin
  distance=0;for(j=0;j<DESC_BITS;j=j+1)distance=distance+(query[j]^rq[j]);
 end
 initial begin
  if((DESC_BITS!=128&&DESC_BITS!=256)||CAPACITY<1||CAPACITY>65535)$fatal(1,"invalid parameters");
 end
 always @(posedge clk) begin
  if(!rst_n)begin
   state<=LOAD;query_count<=0;reference_count<=0;m_valid<=0;done<=0;error<=0;error_code<=0;
   m_query_index<=0;m_reference_index<=0;m_query_metadata<=0;m_reference_metadata<=0;m_best<=0;m_second<=0;m_reason<=0;
  end else if(ce)begin
   done<=0;error<=0;
   case(state)
    LOAD:begin
     if(start_valid)begin
      if(ratio_enable&&ratio_den==0)begin error<=1;error_code<=2;end
      else begin
       limit_snapshot<=max_distance;gap_snapshot<=min_gap;ren<=ratio_enable;rn<=ratio_num;rd<=ratio_den;
       qi<=0;if(query_count==0)begin done<=1;state<=FINISH;end else state<=QREAD;
      end
     end else if(load_valid)begin
      if(load_reference)begin
       if(reference_count==CAPACITY)begin error<=1;error_code<=1;end
       else begin rmem[reference_count]<={load_invalid,load_metadata,load_descriptor};reference_count<=reference_count+1'b1;end
      end else begin
       if(query_count==CAPACITY)begin error<=1;error_code<=1;end
       else begin qmem[query_count]<={load_invalid,load_metadata,load_descriptor};query_count<=query_count+1'b1;end
      end
     end
    end
    QREAD:begin qq<=qmem[qi];state<=QWAIT;end
    QWAIT:begin
     query<=qq[DESC_BITS-1:0];query_invalid<=qq[DESC_BITS+48];m_query_metadata<=qq[DESC_BITS+:48];
     best<=9'h1ff;second<=9'h1ff;best_index<=16'hffff;best_meta<=0;valid_refs<=0;ri<=0;
     if(reference_count==0)state<=PRESENT;else state<=RREAD;
    end
    RREAD:begin rq<=rmem[ri];state<=RWAIT;end
    RWAIT:state<=DIST;
    DIST:begin
     if(!rq[DESC_BITS+48])begin
      valid_refs<=valid_refs+1'b1;
      if(distance<best)begin second<=best;best<=distance;best_index<=ri;best_meta<=rq[DESC_BITS+:48];end
      else if(distance<second)second<=distance;
     end
     if(ri+1>=reference_count)state<=PRESENT;else begin ri<=ri+1'b1;state<=RREAD;end
    end
    PRESENT:begin
     m_query_index<=qi;m_reference_index<=best_index;m_reference_metadata<=best_meta;m_best<=best;m_second<=second;
     // Bitmask: invalid query, no valid reference, distance failure, ambiguity.
     m_reason<={((gap_snapshot!=0&&(valid_refs<2||second-best<gap_snapshot))||(ren&&(valid_refs<2||ratio_left>=ratio_right))),best>limit_snapshot,valid_refs==0,query_invalid};
     m_valid<=1;state<=HOLD;
    end
    HOLD:if(m_ready)begin
     m_valid<=0;if(qi+1>=query_count)begin done<=1;state<=FINISH;end else begin qi<=qi+1'b1;state<=QREAD;end
    end
    FINISH:if(release_valid)begin query_count<=0;reference_count<=0;error_code<=0;state<=LOAD;end
    default:begin state<=FINISH;error<=1;error_code<=3;m_valid<=0;end
   endcase
  end
 end
endmodule
