// Blackbox declarations for GW5A cells instantiated in top.v.
// nextpnr/gowin_pack implement these; sim uses sim/gw5a_clkdiv_sim.v.
module CLKDIV (HCLKIN, RESETN, CALIB, CLKOUT);
input  HCLKIN;
input  RESETN;
input  CALIB;
output CLKOUT;
parameter DIV_MODE = "2";

endmodule
module PLL(CLKIN, CLKFB, RESET, PLLPWD, RESET_I, RESET_O, FBDSEL, IDSEL,
           MDSEL, MDSEL_FRAC, ODSEL0, ODSEL0_FRAC, ODSEL1, ODSEL2, ODSEL3,
           ODSEL4, ODSEL5, ODSEL6, DT0, DT1, DT2, DT3, ICPSEL, LPFRES, LPFCAP,
           PSSEL, PSDIR, PSPULSE, ENCLK0, ENCLK1, ENCLK2, ENCLK3, ENCLK4,
           ENCLK5, ENCLK6, SSCPOL, SSCON, SSCMDSEL, SSCMDSEL_FRAC, LOCK,
           CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6,
           CLKFBOUT);
input CLKIN; input CLKFB; input RESET; input PLLPWD; input RESET_I; input RESET_O;
input [5:0] FBDSEL; input [5:0] IDSEL; input [6:0] MDSEL; input [2:0] MDSEL_FRAC;
input [6:0] ODSEL0; input [2:0] ODSEL0_FRAC; input [6:0] ODSEL1; input [6:0] ODSEL2;
input [6:0] ODSEL3; input [6:0] ODSEL4; input [6:0] ODSEL5; input [6:0] ODSEL6;
input [3:0] DT0,DT1,DT2,DT3; input [5:0] ICPSEL; input [2:0] LPFRES;
input [1:0] LPFCAP; input [2:0] PSSEL; input PSDIR; input PSPULSE;
input ENCLK0,ENCLK1,ENCLK2,ENCLK3,ENCLK4,ENCLK5,ENCLK6;
input SSCPOL, SSCON; input [6:0] SSCMDSEL; input [2:0] SSCMDSEL_FRAC;
output LOCK; output CLKOUT0,CLKOUT1,CLKOUT2,CLKOUT3,CLKOUT4,CLKOUT5,CLKOUT6;
output CLKFBOUT;
endmodule
module DHCEN(CLKIN, CEN, CLKOUT);
input CLKIN; input CEN; output CLKOUT;
endmodule
module BUFG(O, I);
input I; output O;
endmodule
