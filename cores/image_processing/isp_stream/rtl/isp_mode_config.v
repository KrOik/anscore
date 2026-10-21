// Select mathematical identities without changing canonical stage latency.
// cfg_words is the atomically applied16word bank, stable for the whole run.
module isp_mode_config(
 input wire [511:0] cfg_words,
 output wire [47:0] gains,output wire [191:0] matrix,
 output wire blc_bypass,gamma_enable,sobel_bypass,bayer_bypass,
 output wire [1:0] bayer_pattern
);
 localparam [191:0] IDENTITY=192'd1024|(192'd1024<<64)|(192'd1024<<128);
 assign gains=cfg_words[134]?48'h010001000100:cfg_words[303:256];
 assign matrix=cfg_words[135]?IDENTITY:cfg_words[511:320];
 assign blc_bypass=cfg_words[128];assign gamma_enable=cfg_words[129];
 assign sobel_bypass=cfg_words[130];assign bayer_bypass=cfg_words[131];
 assign bayer_pattern=cfg_words[133:132];
endmodule
