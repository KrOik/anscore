// Combinational proof for every48-bit signed accumulator and all shift codes.
module average_equivalence(input signed[47:0] value,input[3:0] shift,output equal);
 wire signed[32:0] coarse=value[47:15];
 wire[15:0] original=value>>>(15+shift);
 wire[15:0] optimized=coarse>>>shift;
 assign equal=original==optimized;
endmodule
