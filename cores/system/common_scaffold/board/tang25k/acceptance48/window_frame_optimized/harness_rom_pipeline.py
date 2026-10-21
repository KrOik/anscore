"""Register acceptance ROM outputs. Requires CE_DIV>=3 and fixed ROM indices between CE edges.
Apply before freezing sources; re-run all UART fault cases and rebuild provenance.
Never apply to already built/programmed cases or pretend old hashes cover new sources.
"""
import re
def register_rom_outputs(text):
 for name in ['configuration','input_word','expected_word','aux_word','coefficient_word']:
  pattern=r'reg \[([^]]+)\] '+name+r';always @\* begin .*?endcase end'
  def register(match):
   return re.sub(r'\b'+name+r'\b',name+'_rom',match.group(0))+f'\nreg [{match.group(1)}] {name};always @(posedge clk) {name}<={name}_rom;'
  text,count=re.subn(pattern,register,text,flags=re.S)
  if count!=1:raise RuntimeError('ROM not found or already pipelined: '+name)
 return text
