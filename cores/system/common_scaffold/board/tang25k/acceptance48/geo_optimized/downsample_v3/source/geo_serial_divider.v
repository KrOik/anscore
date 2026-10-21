// Exact unsigned restoring division, W enabled iterations, common-CE hold.
module geo_serial_divider #(parameter W=32)(input wire clk,rst_n,clk_en,start,input wire [W-1:0] numerator,denominator,output reg done,error,output reg [W-1:0] quotient);
reg busy;reg [W:0] remainder;reg [W-1:0] dividend,divisor;reg [$clog2(W+1)-1:0] count;
wire [W:0] trial={remainder[W-1:0],dividend[W-1]};
wire ge=trial>={1'b0,divisor};
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin done<=0;error<=0;quotient<=0;busy<=0;remainder<=0;dividend<=0;divisor<=0;count<=0;end
 else if(clk_en)begin
  done<=0;
  if(start && !busy)begin
   quotient<=0;remainder<=0;dividend<=numerator;divisor<=denominator;count<=W;error<=denominator==0;
   if(denominator==0)begin done<=1;busy<=0;end else busy<=1;
  end else if(busy)begin
   remainder<=ge?trial-{1'b0,divisor}:trial;
   dividend<=dividend<<1;quotient<={quotient[W-2:0],ge};count<=count-1'b1;
   if(count==1)begin busy<=0;done<=1;end
  end
 end
end
endmodule
