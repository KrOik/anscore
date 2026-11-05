# Declaration/service budget — NOT_RUN

N=W*H, AW=max(1,clog2 N), XW/YW=max(1,clog2 W/H). Two16-bit synchronous frame banks give32N bits; the256x9 table adds2304. Default10496/maximum35072 logical RAM bits. Wrapper scalar/read/output declarations326/383 plus129 W24-divider bits. Physical BRAM depends on depth/width/granularity and small-table mapping; none are mapped measurements.

Per direction: select/read/take/coefficient-read/take/multiply/take/accumulate =8 periods. Center read/take2, four directions32, update/write/next3 give37 per pixel. One bank swap per iteration. Table: A-square/take2, division issue1,24 busy periods, result transfer1, write1 =29 per entry. CHECK1,K-square/take2,final read/take2 give7429 fixed periods. First-visible tails default I4=45321, max I16=613653 after final capture.

One multiplier serves K²,a² and flux magnitude. The table numerator is K²<<8. 256 divisions replace4NI. No image-size-scaled multiplier/divider arrays are needed. Operator input muxes, registers and address control remain part of area cost. An RTL multiplier is not a promise of exactly one hardware DSP.

RAM/difference/index, registered16x9 multiply, signed27 accumulate and shift/round/add update occupy separate states. Width-dependent address selection, RAM inference and control fanout may dominate. Default risk LOW/MEDIUM, maximum MEDIUM. No synthesis, PnR, STA, board, power or Fmax evidence exists. No external-stall wall-time bound.
